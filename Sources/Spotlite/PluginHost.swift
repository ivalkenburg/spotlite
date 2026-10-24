import AppKit
import Security
import UserNotifications
import SpotliteCore

enum PluginCredentials {
    private static func query(_ id: String, _ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.igorv.spotlite.plugin.\(id)", kSecAttrAccount as String: key]
    }
    static func get(_ id: String, _ key: String) throws -> String? {
        var q = query(id, key)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw failure(status) }
        return String(data: data, encoding: .utf8)
    }
    static func set(_ id: String, _ key: String, _ value: String?) throws {
        let q = query(id, key)
        guard let value else {
            let status = SecItemDelete(q as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = q; insert.merge(attributes) { _, new in new }
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }
    static func removeAll(_ id: String) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                               kSecAttrService as String: "com.igorv.spotlite.plugin.\(id)"]
        let status = SecItemDelete(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private static func failure(_ status: OSStatus) -> PluginError {
        .failed("Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))")
    }
}

/// Event-driven subprocess capture with bounded output and process-group cleanup.
@MainActor
private final class PluginSubprocess {
    private let process = Process()
    private let output = Pipe(), errors = Pipe()
    private var stdout = Data(), stderr = Data()
    private var outEnded = false, errEnded = false, exitStatus: Int32?
    private var continuation: CheckedContinuation<PluginValue, Error>?
    private var terminalError: Error?

    func run(runner: URL, executable: String, arguments: [String], directory: String?,
             environment: [String: String]?) async throws -> PluginValue {
        try Task.checkCancellation()
        process.executableURL = runner
        process.arguments = ["--exec", executable] + arguments
        process.standardOutput = output; process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, v in v } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                for (pipe, isError) in [(output, false), (errors, true)] {
                    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                        let data = handle.availableData
                        if data.isEmpty { handle.readabilityHandler = nil }
                        Task { @MainActor in self?.read(data, error: isError) }
                    }
                }
                process.terminationHandler = { [self] process in
                    let status = process.terminationStatus
                    Task { @MainActor in
                        self.exitStatus = status
                        kill(-self.process.processIdentifier, SIGKILL)
                        self.finishIfReady()
                    }
                }
                do { try process.run(); if Task.isCancelled { cancel() } }
                catch { finish(error: error) }
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }

    private func read(_ bytes: Data, error: Bool) {
        if bytes.isEmpty { if error { errEnded = true } else { outEnded = true } }
        else if stdout.count + stderr.count + bytes.count > 3 * 1024 * 1024 {
            terminalError = PluginError.failed("Process output exceeds 3 MiB."); cancel()
        } else if error { stderr.append(bytes) } else { stdout.append(bytes) }
        finishIfReady()
    }
    func cancel() {
        guard continuation != nil else { return }
        if terminalError == nil { terminalError = CancellationError() }
        let pid = process.processIdentifier
        if pid > 0 { kill(-pid, SIGKILL); if process.isRunning { kill(pid, SIGKILL) } }
        if !process.isRunning { finish(error: terminalError) }
    }
    private func finishIfReady() {
        guard let status = exitStatus, outEnded, errEnded else { return }
        let result: PluginValue = .object(["status": .number(Double(status)),
            "stdout": .string(String(decoding: stdout, as: UTF8.self)),
            "stderr": .string(String(decoding: stderr, as: UTF8.self))])
        finish(error: terminalError, result: result)
    }
    private func finish(error: Error?, result: PluginValue = .null) {
        guard let saved = continuation else { return }
        continuation = nil
        process.terminationHandler = nil
        for pipe in [output, errors] { pipe.fileHandleForReading.readabilityHandler = nil; try? pipe.fileHandleForReading.close() }
        if let error { saved.resume(throwing: error) } else { saved.resume(returning: result) }
    }
}

@MainActor
final class PluginHost {
    let store: PluginStore
    let runner: URL
    var onUI: ((String, String, PluginValue, String?) -> Void)?
    var onLog: ((String, String) -> Void)?
    var onToast: ((ToastMessage) -> Void)?
    var onEvent: ((String, PluginValue) -> Void)?
    var onCommandUpdate: ((String, PluginValue) -> Void)?
    private let services = PluginSystemServices()
    private var processes: [String: [UUID: PluginSubprocess]] = [:]

    init(store: PluginStore, runner: URL) {
        self.store = store; self.runner = runner
        services.onEvent = { [weak self] owner, event in self?.onEvent?(owner, event) }
    }
    func cleanup(_ id: String) {
        for operation in processes.removeValue(forKey: id)?.values ?? Dictionary<UUID, PluginSubprocess>().values { operation.cancel() }
        services.cleanup(id)
    }
    func hasResources(_ id: String) -> Bool { services.hasResources(id) || !(processes[id] ?? [:]).isEmpty }

    func settings(_ plugin: InstalledPlugin) async throws -> [String: PluginValue] {
        var result = try await store.settings(plugin.id)
        for field in plugin.manifest.settings ?? [] {
            if field.type == "secret" {
                let value = try await Task.detached { try PluginCredentials.get(plugin.id, field.id) }.value
                result[field.id] = value.map(PluginValue.string) ?? field.defaultValue ?? .null
            } else if result[field.id] == nil { result[field.id] = field.defaultValue ?? .null }
        }
        return result
    }

    func saveSettings(_ plugin: InstalledPlugin, values: [String: PluginValue]) async throws {
        var plain = values
        for field in plugin.manifest.settings ?? [] where field.type == "secret" {
            let secret = values[field.id]?.string
            try await Task.detached { try PluginCredentials.set(plugin.id, field.id, secret?.isEmpty == true ? nil : secret) }.value
            plain.removeValue(forKey: field.id)
        }
        try await store.saveSettings(plugin.id, values: plain)
    }

    func perform(_ method: String, _ args: PluginValue, plugin: InstalledPlugin, context: String? = nil) async throws -> PluginValue {
        try Task.checkCancellation()
        func required(_ key: String) throws -> String {
            guard let value = args[key].string else { throw PluginError.invalid("\(method) requires \(key).") }
            return value
        }
        switch method {
        case "http.request":
            guard let url = URL(string: try required("url")), ["https", "http"].contains(url.scheme) else {
                throw PluginError.invalid("HTTP requests need an http or https URL.")
            }
            var request = URLRequest(url: url)
            request.httpMethod = args["method"].string ?? "GET"
            for (key, value) in args["headers"].object ?? [:] { request.setValue(value.string, forHTTPHeaderField: key) }
            request.httpBody = args["body"].string.map { Data($0.utf8) }
            request.timeoutInterval = min(max(args["timeout"].number ?? 30, 0.1), 3600)
            let (body, http) = try await PluginDownload.data(for: request, limit: 3 * 1024 * 1024)
            var headers: [String: PluginValue] = [:]
            for (key, value) in http.allHeaderFields { headers[String(describing: key).lowercased()] = .string(String(describing: value)) }
            return .object(["status": .number(Double(http.statusCode)), "headers": .object(headers),
                            "body": .string(String(decoding: body, as: UTF8.self)), "base64": .string(body.base64EncodedString())])
        case "process.run":
            let executable = try required("executable")
            let arguments = (args["arguments"].array ?? []).compactMap(\.string)
            let environment = args["environment"].object?.compactMapValues(\.string)
            let operation = PluginSubprocess(), operationID = UUID()
            processes[plugin.id, default: [:]][operationID] = operation
            defer { processes[plugin.id]?.removeValue(forKey: operationID) }
            return try await operation.run(runner: runner, executable: executable,
                arguments: arguments, directory: args["directory"].string, environment: environment)
        case "clipboard.read":
            return NSPasteboard.general.string(forType: .string).map(PluginValue.string) ?? .null
        case "clipboard.write":
            let text = try required("text")
            NSPasteboard.general.clearContents()
            return .bool(NSPasteboard.general.setString(text, forType: .string))
        case "system.open":
            let target = try required("target")
            let url = target.hasPrefix("/") || target.hasPrefix("~")
                ? URL(fileURLWithPath: (target as NSString).expandingTildeInPath) : URL(string: target)
            guard let url else { throw PluginError.invalid("Invalid URL or path.") }
            return .bool(NSWorkspace.shared.open(url))
        case "system.notify":
            let center = UNUserNotificationCenter.current()
            guard try await center.requestAuthorization(options: [.alert, .sound]) else { throw PluginError.failed("Notifications are disabled for Spotlite.") }
            let content = UNMutableNotificationContent()
            content.title = args["title"].string ?? plugin.manifest.name
            content.body = args["body"].string ?? ""
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return .bool(true)
        case "system.info":
            return .object(["pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
                            "osVersion": .string(ProcessInfo.processInfo.operatingSystemVersionString)])
        case "power.create":
            return try services.createAssertion(owner: plugin.id, id: args["id"].string, type: required("type"), name: args["name"].string ?? plugin.manifest.name)
        case "power.get": return services.getAssertion(owner: plugin.id, handle: try required("handle"))
        case "power.release":
            return try services.releaseAssertion(owner: plugin.id, handle: required("handle"))
        case "power.list": return try services.listAssertions()
        case "status.set": return try services.setIndicator(owner: plugin.id, value: args)
        case "status.get": return services.getIndicator(owner: plugin.id, id: try required("id"))
        case "status.remove": return services.removeIndicator(owner: plugin.id, id: try required("id"))
        case "toast.show":
            onToast?(ToastMessage(text: try required("text"), symbol: args["icon"].string ?? "info.circle"))
            return .bool(true)
        case "commands.update":
            let id = try required("id")
            guard plugin.manifest.commands.contains(where: { $0.id == id }) else { throw PluginError.invalid("Unknown command ID.") }
            onCommandUpdate?(plugin.id, args)
            return .bool(true)
        case "storage.paths":
            let data = store.dataURL(plugin.id)
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Spotlite/Plugins/\(plugin.id)", isDirectory: true)
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            return .object(["data": .string(data.path), "cache": .string(cache.path), "package": .string(store.packageURL(plugin).path)])
        case "storage.get": return try await store.storedValue(plugin.id, key: required("key"))
        case "storage.set":
            try await store.storeValue(plugin.id, key: required("key"), value: args["value"]); return .bool(true)
        case "storage.remove":
            try await store.storeValue(plugin.id, key: required("key"), value: nil); return .bool(true)
        case "credentials.get":
            let key = try required("key")
            return try await Task.detached { try PluginCredentials.get(plugin.id, key).map(PluginValue.string) ?? .null }.value
        case "credentials.set", "credentials.remove":
            let key = try required("key"), value = method == "credentials.remove" ? nil : try required("value")
            try await Task.detached { try PluginCredentials.set(plugin.id, key, value) }.value
            return .bool(true)
        case "settings.get": return .object(try await settings(plugin))
        case "settings.set":
            guard let values = args.object else { throw PluginError.invalid("Settings must be an object.") }
            try await saveSettings(plugin, values: values); return .bool(true)
        case "timers.sleep":
            let seconds = args["seconds"].number ?? 0
            guard seconds >= 0, seconds <= 365 * 24 * 3600 else { throw PluginError.invalid("Invalid sleep duration.") }
            try await Task.sleep(for: .seconds(seconds), tolerance: .seconds(min(seconds, max(0, args["tolerance"].number ?? 0)))); return .bool(true)
        case "ui.push", "ui.replace", "ui.update", "ui.pop", "ui.close":
            if ["ui.push", "ui.replace", "ui.update"].contains(method) {
                try args.decode(PluginView.self).validate()
            }
            onUI?(plugin.id, method, args, context)
            return .bool(true)
        case "log":
            onLog?(plugin.id, args["message"].string ?? "")
            return .bool(true)
        default: throw PluginError.invalid("Unknown host API: \(method).")
        }
    }

}
