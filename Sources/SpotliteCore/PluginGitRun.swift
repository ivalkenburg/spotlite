import Foundation

/// A git invocation with bounded pipe buffers and a cancellable deadline. Reading
/// while git runs avoids blocking a clone when its diagnostics fill the pipe.
final class PluginGitRun: @unchecked Sendable {
    struct Output: Sendable {
        let code: Int32
        let output: String
        let error: String
    }

    private let queue = DispatchQueue(label: "com.igorv.spotlite.plugin-git", qos: .userInitiated)
    private let process = Process()
    private var group: pid_t?
    private var continuation: CheckedContinuation<Result<Output, PluginInstallError>, Never>?
    private var output = TailBuffer(limit: 4096)
    private var errors = TailBuffer(limit: 16 * 1024)
    private var channels: [DispatchIO] = []
    private var ended = 0
    private var status: Int32?
    private var deadline: DispatchSourceTimer?
    private var failure: PluginInstallError?
    private var finished = false

    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval)
        async throws(PluginInstallError) -> Output {
        let run = PluginGitRun()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                run.queue.async { run.launch(executable, arguments: arguments, timeout: timeout, continuation: continuation) }
            }
        } onCancel: {
            run.queue.async { run.stop(.cancelled) }
        }
        if Task.isCancelled { throw .cancelled }
        return try result.get()
    }

    private func launch(_ executable: URL, arguments: [String], timeout: TimeInterval,
                        continuation: CheckedContinuation<Result<Output, PluginInstallError>, Never>) {
        self.continuation = continuation
        if let failure { return complete(.failure(failure)) }
        process.executableURL = executable
        process.arguments = arguments
        var environment = ["PATH": "/usr/bin:/bin", "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false",
                           "SSH_ASKPASS": "/usr/bin/false", "GCM_INTERACTIVE": "never", "LC_ALL": "C"]
        environment["HOME"] = ProcessInfo.processInfo.environment["HOME"]
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [self] process in
            let code = process.terminationStatus
            queue.async {
                self.status = code
                self.finishIfReady()
                // A child may have inherited a pipe. Git itself has finished; don't
                // wait indefinitely for the inherited descriptor to close.
                if !self.finished {
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
                        self.channels.forEach { $0.close(flags: .stop) }
                    }
                }
            }
        }
        do { try process.run() }
        catch { return complete(.failure(.download("Couldn’t start git."))) }
        let pid = process.processIdentifier
        if getpgid(pid) == pid, pid != getpgrp() { group = pid }
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        channels = [read(out, isError: false), read(err, isError: true)]

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.stop(.download("git took too long.")) }
        deadline = timer
        timer.resume()
    }

    private func read(_ pipe: Pipe, isError: Bool) -> DispatchIO {
        let channel = DispatchIO(type: .stream, fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
                                 queue: queue) { _ in _ = pipe }
        channel.setLimit(lowWater: 1)
        channel.read(offset: 0, length: .max, queue: queue) { [self] done, data, _ in
            guard !finished else { return }
            if let data {
                if isError { errors.append(Data(data)) }
                else { output.append(Data(data)) }
            }
            if done {
                ended += 1
                finishIfReady()
            }
        }
        return channel
    }

    private func finishIfReady() {
        guard let status, ended == 2 else { return }
        let text = { (data: Data) in String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        let lastError = text(errors.bytes).split(separator: "\n").last.map(String.init) ?? ""
        complete(.success(Output(code: status, output: text(output.bytes), error: String(lastError.prefix(300)))))
    }

    private func stop(_ error: PluginInstallError) {
        guard !finished, failure == nil else { return }
        failure = error
        if process.isRunning || group != nil {
            if process.isRunning { process.terminate() }
            let process = process, group = group
            queue.asyncAfter(deadline: .now() + .seconds(1)) {
                if let group { kill(-group, SIGKILL) }
                else if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        // Cancellation may arrive before launch installs its continuation.
        if continuation != nil { complete(.failure(error)) }
    }

    private func complete(_ result: Result<Output, PluginInstallError>) {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        deadline = nil
        process.terminationHandler = nil
        channels.forEach { $0.close(flags: .stop) }
        channels.removeAll()
        continuation?.resume(returning: result)
        continuation = nil
    }
}
