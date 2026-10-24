import Foundation
import SpotliteCore

/// Reads are driven by pipe readiness. Writes never block the main actor, including
/// when an unrestricted plugin stops consuming its input.
private final class PluginWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Spotlite.plugin-input", qos: .userInitiated)
    private let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func send(_ data: Data, failure: @escaping @Sendable (String) -> Void) {
        queue.async { [handle] in
            do { try handle.write(contentsOf: data) } catch { failure(error.localizedDescription) }
        }
    }
    func close() { queue.async { [handle] in try? handle.close() } }
}

@MainActor
final class PluginSession {
    let plugin: InstalledPlugin
    let process = Process()
    var onHostCall: ((String, PluginValue, String, String?) async throws -> PluginValue)?
    var onFailure: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    var onIdle: (() -> Void)?
    private var writer: PluginWriter?
    private var output = Data()
    private var logBuffer = Data()
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var pending: [String: CheckedContinuation<PluginValue, Error>] = [:]
    private var contexts: [String: String] = [:]
    private var jobs: [String: (parent: String, task: Task<Void, Never>)] = [:]
    private var stopping = false
    private var terminated = false
    var pendingCount: Int { pending.count }
    private var backgroundTasks = Set<String>()
    var hasBackgroundTasks: Bool { !backgroundTasks.isEmpty }

    init(plugin: InstalledPlugin) { self.plugin = plugin }

    func launch(runner: URL, bootstrap: URL, package: URL) throws {
        let input = Pipe(), output = Pipe(), logs = Pipe()
        process.executableURL = runner
        process.arguments = [bootstrap.path, package.path]
        process.currentDirectoryURL = package
        process.standardInput = input
        process.standardOutput = output
        process.standardError = logs
        stdout = output.fileHandleForReading
        stderr = logs.fileHandleForReading
        writer = PluginWriter(input.fileHandleForWriting)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            Task { @MainActor in self?.receive(bytes) }
        }
        logs.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            Task { @MainActor in self?.receiveLog(bytes) }
        }
        process.terminationHandler = { [self] process in
            let status = process.terminationStatus
            Task { @MainActor in self.exited(status) }
        }
        do { try process.run() }
        catch { process.terminationHandler = nil; cleanPipes(); throw error }
    }

    func request(_ method: String, params: PluginValue, context: String? = nil) async throws -> PluginValue {
        try Task.checkCancellation()
        guard !stopping, process.isRunning else { throw PluginError.stopped }
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                contexts[id] = context
                if Task.isCancelled { cancel(id); return }
                send(PluginMessage(id: id, method: method, params: params))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    private func cancel(_ id: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        contexts.removeValue(forKey: id)
        send(PluginMessage(method: "cancel", params: .object(["id": .string(id)])))
        cancelJobs(parent: id)
        continuation.resume(throwing: CancellationError())
        onIdle?()
    }

    private func cancelJobs(parent: String) {
        let matching = jobs.filter { $0.value.parent == parent }
        for (id, job) in matching { jobs.removeValue(forKey: id); job.task.cancel() }
    }

    func stop(force: Bool = false) {
        guard !terminated else { return }
        stopping = true
        for continuation in pending.values { continuation.resume(throwing: PluginError.stopped) }
        pending.removeAll()
        contexts.removeAll()
        jobs.values.forEach { $0.task.cancel() }; jobs.removeAll()
        guard process.isRunning else { cleanPipes(); return }
        let pid = process.processIdentifier
        // The C entry point establishes a process group before loading plugin code.
        // Signal the PID as well: Stop may race with the child's setpgid call.
        kill(-pid, force ? SIGKILL : SIGTERM)
        kill(pid, force ? SIGKILL : SIGTERM)
        writer?.close()
        if !force {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.process.isRunning else { return }
                kill(-pid, SIGKILL); kill(pid, SIGKILL)
            }
        }
    }

    private func send(_ message: PluginMessage) {
        do {
            var bytes = try JSONEncoder().encode(message)
            guard bytes.count <= 4 * 1024 * 1024 else { throw PluginError.invalid("Plugin message exceeds 4 MiB.") }
            bytes.append(10)
            writer?.send(bytes) { [weak self] problem in
                Task { @MainActor in self?.fail(problem) }
            }
        } catch { fail(error.localizedDescription) }
    }

    private func receive(_ bytes: Data) {
        guard !bytes.isEmpty else { stdout?.readabilityHandler = nil; return }
        output.append(bytes)
        while let newline = output.firstIndex(of: 10) {
            let line = output[..<newline]
            guard line.count <= 4 * 1024 * 1024 else { fail("Plugin message exceeds 4 MiB."); return }
            do {
                let message = try JSONDecoder().decode(PluginMessage.self, from: line)
                output.removeSubrange(...newline)
                handle(message)
            } catch { fail("Invalid plugin response: \(error.localizedDescription)"); return }
        }
        if output.count > 4 * 1024 * 1024 { fail("Plugin message exceeds 4 MiB.") }
    }

    private func handle(_ message: PluginMessage) {
        guard !stopping else { return }
        if let method = message.method {
            if method == "background.started" || method == "background.finished" || method == "background.cancelled" {
                guard plugin.manifest.keepsAlive, let id = message.params?["id"].string else {
                    fail("Background work requires background: true in the manifest."); return
                }
                if method == "background.started" { backgroundTasks.insert(id) }
                else {
                    if method == "background.cancelled" { cancelJobs(parent: id) }
                    backgroundTasks.remove(id); onIdle?()
                }
                return
            }
            if method == "log", message.id == nil {
                onLog?(message.params?["message"].string ?? "Plugin error")
                return
            }
            guard let id = message.id, let envelope = message.params,
                  let parent = envelope["task"].string else { fail("Host call is missing its task ID."); return }
            let background = parent.hasPrefix("background:") && plugin.manifest.keepsAlive
            guard pending[parent] != nil || background else {
                send(PluginMessage(id: id, error: "Request cancelled, or background work was not declared.")); return
            }
            guard jobs[id] == nil else { fail("Duplicate host call ID."); return }
            let arguments = envelope["arguments"]
            let context = contexts[parent]
            jobs[id] = (parent, Task { [weak self] in
                guard let self else { return }
                do {
                    try Task.checkCancellation()
                    guard let onHostCall = self.onHostCall else { throw PluginError.stopped }
                    let result = try await onHostCall(method, arguments, parent, context)
                    try Task.checkCancellation()
                    guard try JSONEncoder().encode(result).count < 4 * 1024 * 1024 - 1024 else {
                        throw PluginError.failed("Host API result exceeds the 4 MiB message limit.")
                    }
                    guard self.jobs.removeValue(forKey: id) != nil, !self.stopping else { return }
                    self.send(PluginMessage(id: id, result: result))
                } catch {
                    guard self.jobs.removeValue(forKey: id) != nil, !self.stopping else { return }
                    self.send(PluginMessage(id: id, error: error.localizedDescription))
                }
            })
        } else if let id = message.id, let continuation = pending.removeValue(forKey: id) {
            contexts.removeValue(forKey: id)
            cancelJobs(parent: id)
            if let error = message.error { continuation.resume(throwing: PluginError.failed(error)) }
            else { continuation.resume(returning: message.result ?? .null) }
            onIdle?()
        }
    }

    private func receiveLog(_ bytes: Data) {
        guard !bytes.isEmpty else { stderr?.readabilityHandler = nil; return }
        logBuffer.append(bytes)
        while let newline = logBuffer.firstIndex(of: 10) {
            onLog?(String(decoding: logBuffer[..<newline].prefix(8192), as: UTF8.self))
            logBuffer.removeSubrange(...newline)
        }
        if logBuffer.count > 8192 {
            onLog?(String(decoding: logBuffer.prefix(8192), as: UTF8.self)); logBuffer.removeAll(keepingCapacity: true)
        }
    }

    private func fail(_ problem: String) {
        guard !stopping else { return }
        onLog?(problem)
        stop(force: true)
        onFailure?(problem)
    }

    private func exited(_ status: Int32) {
        guard !terminated else { return }
        terminated = true
        process.terminationHandler = nil
        // Reap descendants even if the Lua runner itself exited normally.
        kill(-process.processIdentifier, SIGKILL)
        let expected = stopping
        for continuation in pending.values { continuation.resume(throwing: PluginError.failed("Plugin exited (\(status)).")) }
        pending.removeAll()
        jobs.values.forEach { $0.task.cancel() }; jobs.removeAll()
        cleanPipes()
        if !expected { onFailure?("Plugin exited (\(status)). Choose Restart to try again.") }
    }

    private func cleanPipes() {
        stdout?.readabilityHandler = nil; stderr?.readabilityHandler = nil
        try? stdout?.close(); try? stderr?.close()
        stdout = nil; stderr = nil
        writer?.close(); writer = nil
    }
}
