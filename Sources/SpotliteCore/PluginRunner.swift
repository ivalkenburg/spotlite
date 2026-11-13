import Foundation

public enum PluginRunError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut
    case cancelled
    /// Non-zero exit, with the first line the program wrote to standard error.
    case failed(status: Int32, message: String)
    case outputTooLarge
    case invalidOutput(String)

    public var message: String {
        switch self {
        case .launchFailed(let reason): "Couldn’t start the plugin: \(reason)"
        case .timedOut: "The plugin took too long"
        case .cancelled: "Cancelled"
        case .failed(let status, let message): message.isEmpty ? "The plugin failed (exit \(status))" : message
        case .outputTooLarge: "The plugin returned too much data"
        case .invalidOutput: "The plugin returned invalid JSON"
        }
    }
}

/// One run of a plugin's executable. Nothing exists between runs: no helper process,
/// no thread, no timer. A run is a child process whose output arrives through
/// dispatch I/O, so no thread blocks while it works.
public final class PluginRun: @unchecked Sendable {
    public typealias Completion = @Sendable (Result<PluginResponse, PluginRunError>) -> Void

    /// Enough for hundreds of rows; a runaway program is stopped rather than buffered.
    static let maxOutput = 4 * 1024 * 1024
    private static let maxErrorOutput = 16 * 1024

    /// Every field below is touched only on this queue.
    private let queue = DispatchQueue(label: "com.igorv.spotlite.plugin", qos: .userInitiated)
    private let process = Process()
    private let completion: Completion
    private var output = Data()
    private var errorOutput = Data()
    private var outputChannel: DispatchIO?
    private var errorChannel: DispatchIO?
    private var timeout: DispatchWorkItem?
    private var exitStatus: Int32?
    private var outputEnded = false
    private var stopReason: PluginRunError?
    private var finished = false

    /// Starts `executable` with `arguments`. `completion` is called once, on a
    /// background queue, unless the run is cancelled first.
    @discardableResult
    public static func start(executable: URL, arguments: [String], environment: [String: String],
                             directory: URL, timeout: TimeInterval,
                             completion: @escaping Completion) -> PluginRun {
        let run = PluginRun(completion: completion)
        run.queue.async {
            run.launch(executable: executable, arguments: arguments, environment: environment,
                       directory: directory, timeout: timeout)
        }
        return run
    }

    private init(completion: @escaping Completion) {
        self.completion = completion
    }

    /// Stops the program; the completion is not called.
    public func cancel() {
        queue.async { self.stop(.cancelled) }
    }

    private func launch(executable: URL, arguments: [String], environment: [String: String],
                        directory: URL, timeout seconds: TimeInterval) {
        guard stopReason == nil else { return }
        let outputPipe = Pipe(), errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [self] finishedProcess in
            let status = finishedProcess.terminationStatus
            queue.async {
                self.exitStatus = status
                self.finishIfReady()
                guard !self.outputEnded else { return }
                // Something the program left running still holds the pipe. Take what
                // was written rather than waiting for a stranger to exit.
                self.queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
                    self.outputChannel?.close(flags: .stop)
                }
            }
        }
        do {
            try process.run()
        } catch {
            finished = true
            // The handler holds this run, and will never be called to let go of it.
            process.terminationHandler = nil
            completion(.failure(.launchFailed(error.localizedDescription)))
            return
        }
        // The child has its own copies; ours would keep the pipes from ever ending.
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        outputChannel = read(outputPipe) { [self] chunk, ended in
            // A stopped run reports no output, so what still arrives is not kept.
            if stopReason == nil {
                output.append(chunk)
                if output.count > PluginRun.maxOutput { stop(.outputTooLarge) }
            }
            if ended {
                outputEnded = true
                finishIfReady()
            }
        }
        errorChannel = read(errorPipe) { [self] chunk, _ in
            let room = PluginRun.maxErrorOutput - errorOutput.count
            if room > 0 { errorOutput.append(chunk.prefix(room)) }
        }

        let deadline = DispatchWorkItem { [self] in stop(.timedOut) }
        timeout = deadline
        queue.asyncAfter(deadline: .now() + seconds, execute: deadline)
    }

    /// Reads a pipe to its end on the run's queue. The pipe object is held until the
    /// channel closes, since it owns the descriptor.
    private func read(_ pipe: Pipe, handler: @escaping (Data, Bool) -> Void) -> DispatchIO {
        let channel = DispatchIO(type: .stream, fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
                                 queue: queue) { _ in _ = pipe }
        channel.setLimit(lowWater: 1)
        channel.read(offset: 0, length: .max, queue: queue) { done, data, _ in
            var chunk = Data()
            if let data, !data.isEmpty { chunk = Data(data) }
            handler(chunk, done)
        }
        return channel
    }

    private func stop(_ reason: PluginRunError) {
        guard !finished, stopReason == nil else { return }
        stopReason = reason
        if process.isRunning {
            process.terminate()
            // A program that ignores the request is not left running behind the panel.
            let process = process
            queue.asyncAfter(deadline: .now() + .seconds(1)) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        // A cancelled run reports nothing, so it need not wait for the exit.
        if reason == .cancelled { finish() }
    }

    private func finishIfReady() {
        if exitStatus != nil, outputEnded { finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        timeout = nil
        outputChannel?.close(flags: .stop)
        errorChannel?.close(flags: .stop)
        outputChannel = nil
        errorChannel = nil
        process.terminationHandler = nil

        if let stopReason {
            if stopReason != .cancelled { completion(.failure(stopReason)) }
            return
        }
        let status = exitStatus ?? 0
        guard status == 0 else {
            let text = String(decoding: errorOutput, as: UTF8.self)
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            completion(.failure(.failed(status: status, message: line)))
            return
        }
        do {
            completion(.success(try PluginResponse.decode(output)))
        } catch {
            completion(.failure(.invalidOutput(String(describing: error))))
        }
    }
}

public enum PluginEnvironment {
    /// A GUI app inherits launchd's short PATH, which has none of the places command
    /// line tools are installed to.
    static let extraPaths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]

    /// The environment a plugin runs in: Spotlite's own, a usable PATH, and the
    /// `SPOTLITE_*` variables that say where the plugin lives and what was typed.
    public static func make(for plugin: InstalledPlugin, query: String,
                            base: [String: String] = ProcessInfo.processInfo.environment,
                            dataDirectory: URL? = nil) -> [String: String] {
        var environment = base
        let inherited = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        environment["PATH"] = (inherited + extraPaths.filter { !inherited.contains($0) }).joined(separator: ":")
        environment["SPOTLITE_PLUGIN_ID"] = plugin.id
        environment["SPOTLITE_PLUGIN_DIR"] = plugin.directory.path
        environment["SPOTLITE_PLUGIN_DATA"] = (dataDirectory ?? PluginStore.dataDirectory(for: plugin.id)).path
        environment["SPOTLITE_QUERY"] = query
        return environment
    }
}
