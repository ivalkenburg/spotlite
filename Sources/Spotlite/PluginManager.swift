import AppKit
import CryptoKit
import SpotliteCore

extension Notification.Name {
    static let spotlitePluginsChanged = Notification.Name("SpotlitePluginsChanged")
}

struct PluginUpdate: Codable, Sendable {
    let version: String
    let apiVersion: Int
    let downloadURL: String
    let sha256: String
}

private final class PluginLog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Spotlite.plugin-log", qos: .utility)
    private let root: URL
    init(root: URL) { self.root = root }
    func append(_ id: String, _ message: String) {
        queue.async { [root] in
            let file = root.appendingPathComponent("\(id).log")
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 256 * 1024 {
                    let previous = root.appendingPathComponent("\(id).previous.log")
                    try? FileManager.default.removeItem(at: previous)
                    try FileManager.default.moveItem(at: file, to: previous)
                }
                let bytes = Data("\(Date().ISO8601Format()) \(message.prefix(8192))\n".utf8)
                if !FileManager.default.fileExists(atPath: file.path) { try bytes.write(to: file) }
                else {
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    try handle.seekToEnd(); try handle.write(contentsOf: bytes)
                }
            } catch { NSLog("Spotlite: could not write plugin log: %@", error.localizedDescription) }
        }
    }
}

@MainActor
final class PluginManager {
    let store: PluginStore
    let host: PluginHost
    private(set) var plugins: [InstalledPlugin] = []
    private(set) var failures: [String: String] = [:]
    private(set) var loadError: String?
    private(set) var isLoaded = false
    var onUI: ((String, String, PluginValue, String?) -> Void)?
    private let resources: URL
    private let log: PluginLog
    private var sessions: [String: PluginSession] = [:]
    private var initializing: [String: Task<PluginSession, Error>] = [:]
    private var generations: [String: Int] = [:]
    private var leases = Set<String>()
    private var stopped = Set<String>()
    private(set) var commandIndex = PluginCommandIndex(plugins: [])
    private var loading: Task<Void, Never>?
    private let legacyHiddenUtilityIDs: Set<String>
    private var commandOverrides: [String: [String: PluginValue]] = [:]
    private var shuttingDown = false

    init(legacyHiddenUtilityIDs: Set<String> = [], root: URL = PluginStore.defaultRoot, resources: URL? = nil) {
        self.legacyHiddenUtilityIDs = legacyHiddenUtilityIDs
        store = PluginStore(root: root)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let inBundle = Bundle.main.bundleURL.pathExtension == "app"
        let runner = inBundle
            ? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SpotlitePluginRunner")
            : executable.deletingLastPathComponent().appendingPathComponent("SpotlitePluginRunner")
        self.resources = resources ?? (inBundle ? Bundle.main.resourceURL! :
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources"))
        host = PluginHost(store: store, runner: runner)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spotlite/PluginLogs", isDirectory: true)
        log = PluginLog(root: caches)
        signal(SIGPIPE, SIG_IGN)
        host.onUI = { [weak self] id, method, args, context in self?.onUI?(id, method, args, context) }
        host.onLog = { [weak self] id, message in self?.log.append(id, message) }
        host.onEvent = { [weak self] id, event in
            Task { @MainActor in
                guard let self else { return }
                do { _ = try await self.request(id, method: "event", params: event, context: "event") }
                catch { self.log.append(id, error.localizedDescription) }
            }
        }
        host.onCommandUpdate = { [weak self] id, value in
            guard let self, let command = value["id"].string else { return }
            self.commandOverrides[id, default: [:]][command] = value
            self.changed(rebuild: true, commandOwner: id)
        }
    }

    func load() {
        guard loading == nil, !isLoaded else { return }
        loading = Task { [weak self] in
            guard let self else { return }
            do {
                self.plugins = try await self.store.load(bundledDirectory: self.resources.appendingPathComponent("Plugins"), legacyHiddenUtilityIDs: self.legacyHiddenUtilityIDs)
                self.isLoaded = true
                self.loadError = nil
                self.changed(rebuild: true)
                for plugin in self.plugins where plugin.enabled && plugin.manifest.startsAtLaunch {
                    Task { @MainActor in
                        do { _ = try await self.start(plugin.id); self.releaseIfIdle(plugin.id) }
                        catch { if !self.shuttingDown && !self.stopped.contains(plugin.id) { self.recordFailure(plugin.id, error.localizedDescription) } }
                    }
                }
            } catch { self.loadError = error.localizedDescription; self.changed() }
            self.loading = nil
        }
    }

    func waitUntilLoaded() async throws {
        load()
        await loading?.value
        guard isLoaded else { throw PluginError.failed(loadError ?? "Plugin registry is not available.") }
    }

    func prefixMatch(_ query: String) -> (PluginCommandReference, String)? {
        for reference in commandIndex.commands {
            guard let prefix = reference.command.prefix, !prefix.isEmpty,
                  query.prefix(prefix.count + 1).lowercased() == prefix.lowercased() + " " else { continue }
            return (reference, String(query.dropFirst(prefix.count + 1)))
        }
        return nil
    }

    var globalCommands: [PluginCommandReference] {
        commandIndex.commands.filter { $0.plugin.globalSearch && $0.command.global == true }
    }

    func acquire(_ id: String) { leases.insert(id) }
    func release(_ id: String) { leases.remove(id); releaseIfIdle(id) }
    func status(_ id: String) -> String {
        if failures[id] != nil { return "Failed" }
        if stopped.contains(id) { return "Stopped" }
        if initializing[id] != nil { return "Starting…" }
        if sessions[id] != nil { return host.hasResources(id) ? "Active" : "Running" }
        return plugins.first(where: { $0.id == id })?.enabled == true ? "Ready" : "Disabled"
    }
    var runningProcessIDs: [String: Int32] { sessions.mapValues { $0.process.processIdentifier } }

    private func start(_ id: String) async throws -> PluginSession {
        guard !shuttingDown else { throw PluginError.stopped }
        if let task = initializing[id] { return try await task.value }
        if let session = sessions[id] { return session }
        guard !stopped.contains(id), failures[id] == nil else { throw PluginError.failed(failures[id] ?? "Plugin is stopped. Choose Restart in Plugins settings.") }
        guard let plugin = plugins.first(where: { $0.id == id && $0.enabled }) else { throw PluginError.invalid("Plugin is disabled or not installed.") }
        let session = PluginSession(plugin: plugin)
        let generation = generations[id, default: 0]
        let task = Task<PluginSession, Error> { [self, session] in
            try Task.checkCancellation()
            session.onHostCall = { [weak self] method, args, _, context in
                guard let self else { throw PluginError.stopped }
                return try await self.host.perform(method, args, plugin: plugin, context: context)
            }
            session.onFailure = { [weak self, weak session] problem in
                guard let self, self.sessions[id] === session else { return }
                self.recordFailure(id, problem)
            }
            session.onLog = { [weak self] message in self?.log.append(id, message) }
            session.onIdle = { [weak self] in
                // Defer until all messages in this pipe batch (including background
                // startup notices) have been consumed.
                Task { @MainActor in self?.releaseIfIdle(id) }
            }
            try session.launch(runner: self.host.runner, bootstrap: self.resources.appendingPathComponent("PluginRuntime/bootstrap.lua"),
                               package: self.store.packageURL(plugin))
            self.sessions[id] = session
            _ = try await session.request("initialize", params: .object([
                "id": .string(id), "entry": .string(plugin.manifest.entryPoint),
                "apiVersion": .number(1), "version": .string(plugin.manifest.version),
                "testEntry": plugin.manifest.testEntry.map(PluginValue.string) ?? .null]))
            return session
        }
        initializing[id] = task
        changed()
        do {
            let result = try await task.value
            guard generations[id, default: 0] == generation else { throw CancellationError() }
            initializing[id] = nil; changed()
            return result
        } catch {
            if generations[id, default: 0] == generation {
                initializing[id] = nil
                if !Task.isCancelled, !(error is CancellationError), !stopped.contains(id) { recordFailure(id, error.localizedDescription) }
            }
            throw error
        }
    }

    func request(_ id: String, method: String, params: PluginValue, context: String? = nil) async throws -> PluginValue {
        try Task.checkCancellation()
        let session = try await start(id)
        defer { releaseIfIdle(id) }
        do { return try await session.request(method, params: params, context: context) }
        catch {
            if !(error is CancellationError) { log.append(id, "\(method): \(error.localizedDescription)") }
            throw error
        }
    }

    func search(_ reference: PluginCommandReference, query: String, view: PluginView? = nil,
                global: Bool = false, context: String? = nil) async throws -> PluginView {
        var args: [String: PluginValue] = ["command": .string(reference.command.id),
            "title": .string(reference.command.title), "query": .string(query), "global": .bool(global)]
        if let view { args["view"] = try .encode(view) }
        let result = try await request(reference.plugin.id, method: "search", params: .object(args), context: global ? "global" : context)
        let rendered = try result.decode(PluginView.self)
        try rendered.validate()
        return rendered
    }

    func stop(_ id: String, force: Bool = false, userInitiated: Bool = true) {
        generations[id, default: 0] &+= 1
        initializing.removeValue(forKey: id)?.cancel()
        sessions.removeValue(forKey: id)?.stop(force: force)
        host.cleanup(id)
        let hadOverrides = commandOverrides.removeValue(forKey: id) != nil
        if userInitiated { stopped.insert(id) }
        changed(rebuild: hadOverrides)
    }
    func restart(_ id: String) async throws {
        stop(id)
        if let plugin = plugins.first(where: { $0.id == id }), plugin.developmentPath != nil {
            let refreshed = try await store.refreshDevelopment(id)
            plugins = plugins.map { $0.id == id ? refreshed : $0 }
            changed(rebuild: true)
        }
        stopped.remove(id); failures.removeValue(forKey: id)
        _ = try await start(id)
        releaseIfIdle(id)
    }
    func shutdown() {
        shuttingDown = true
        for id in Set(sessions.keys).union(initializing.keys) { stop(id, force: true, userInitiated: false) }
    }
    private func releaseIfIdle(_ id: String) {
        guard initializing[id] == nil, !leases.contains(id),
              let session = sessions[id], session.pendingCount == 0, !session.hasBackgroundTasks else { return }
        if !session.plugin.manifest.keepsAlive { host.cleanup(id) }
        guard !host.hasResources(id) else { return }
        stop(id, userInitiated: false)
    }
    private func recordFailure(_ id: String, _ problem: String) {
        failures[id] = problem
        log.append(id, problem)
        stop(id, force: true, userInitiated: false)
    }

    func install(_ source: URL, development: Bool = false) async throws {
        try await waitUntilLoaded()
        let folder = source.lastPathComponent == "manifest.json" ? source.deletingLastPathComponent() : source
        let record = try await store.install(folder, development: development)
        stop(record.id)
        plugins = try await store.load()
        stopped.remove(record.id); failures.removeValue(forKey: record.id)
        changed(rebuild: true)
        if record.manifest.startsAtLaunch { _ = try await start(record.id); releaseIfIdle(record.id) }
    }
    func setEnabled(_ id: String, _ enabled: Bool) async throws {
        plugins = try await store.setEnabled(id, enabled)
        if enabled {
            stopped.remove(id); failures.removeValue(forKey: id)
            if plugins.first(where: { $0.id == id })?.manifest.startsAtLaunch == true { _ = try await start(id); releaseIfIdle(id) }
        } else { stop(id, userInitiated: false) }
        changed(rebuild: true)
    }
    func setGlobalSearch(_ id: String, _ enabled: Bool) async throws {
        plugins = try await store.setGlobalSearch(id, enabled); changed(rebuild: true)
    }
    func setShowCommands(_ id: String, _ visible: Bool) async throws {
        plugins = try await store.setShowCommands(id, visible); changed(rebuild: true)
    }
    func uninstall(_ id: String, removeData: Bool) async throws {
        stop(id, force: true)
        if removeData { try await Task.detached { try PluginCredentials.removeAll(id) }.value }
        plugins = try await store.uninstall(id, removeData: removeData)
        failures.removeValue(forKey: id); stopped.remove(id)
        changed(rebuild: true)
    }
    func rollback(_ id: String) async throws {
        _ = try await store.rollback(id)
        stop(id)
        plugins = try await store.load()
        stopped.remove(id); failures.removeValue(forKey: id)
        changed(rebuild: true)
        if plugins.first(where: { $0.id == id && $0.enabled })?.manifest.startsAtLaunch == true {
            _ = try await start(id); releaseIfIdle(id)
        }
    }

    func checkUpdate(_ plugin: InstalledPlugin) async throws -> PluginUpdate? {
        guard let raw = plugin.manifest.updateURL, let url = URL(string: raw), url.scheme == "https" else { return nil }
        let (data, response) = try await PluginDownload.data(for: URLRequest(url: url), limit: 65_536)
        guard response.statusCode == 200 else { throw PluginError.failed("Could not read plugin update information.") }
        let update = try JSONDecoder().decode(PluginUpdate.self, from: data)
        guard update.apiVersion == PluginManifest.supportedAPIVersion else { throw PluginError.invalid("The available update requires a different Spotlite API version. Your installed version was preserved.") }
        guard let current = PluginVersion(plugin.manifest.version), let newer = PluginVersion(update.version) else { throw PluginError.invalid("Invalid update version.") }
        guard newer > current else { return nil }
        guard let download = URL(string: update.downloadURL), download.scheme == "https", download.host != nil,
              update.sha256.count == 64, update.sha256.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw PluginError.invalid("Updates need an HTTPS download and a SHA-256 checksum.")
        }
        return update
    }
    func applyUpdate(_ update: PluginUpdate, id: String) async throws {
        guard let url = URL(string: update.downloadURL) else { throw PluginError.invalid("Invalid download URL.") }
        let (file, response) = try await PluginDownload.file(for: URLRequest(url: url), limit: 80 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }
        guard response.statusCode == 200 else { throw PluginError.failed("Plugin download failed.") }
        let checksum = try await Task.detached {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty { hash.update(data: chunk) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        guard checksum == update.sha256.lowercased() else { throw PluginError.failed("Plugin checksum does not match. The installed version was preserved.") }
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: file, to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }
        _ = try await store.install(archive, expectedID: id, expectedVersion: update.version)
        stop(id)
        plugins = try await store.load(); stopped.remove(id); failures.removeValue(forKey: id)
        changed(rebuild: true)
        if plugins.first(where: { $0.id == id && $0.enabled })?.manifest.startsAtLaunch == true {
            _ = try await start(id); releaseIfIdle(id)
        }
    }

    func logURL(_ id: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spotlite/PluginLogs/\(id).log")
    }

    private func changed(rebuild: Bool = false, commandOwner: String? = nil) {
        if rebuild {
            let displayed = plugins.map { plugin -> InstalledPlugin in
                var value = plugin
                value.manifest.commands = plugin.manifest.commands.map { command in
                    guard let override = commandOverrides[plugin.id]?[command.id] else { return command }
                    var updated = command
                    updated.icon = override["icon"].string ?? command.icon
                    updated.title = override["title"].string ?? command.title
                    updated.subtitle = override["subtitle"].string ?? command.subtitle
                    return updated
                }
                return value
            }
            commandIndex = PluginCommandIndex(plugins: displayed, root: store.root)
        }
        var info: [String: Any] = ["commandsChanged": rebuild]
        if let commandOwner { info["commandOwner"] = commandOwner }
        NotificationCenter.default.post(name: .spotlitePluginsChanged, object: self, userInfo: info)
    }
}
