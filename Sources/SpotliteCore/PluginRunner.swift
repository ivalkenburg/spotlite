import Foundation

public enum PluginRunError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut
    case cancelled
    /// Non-zero exit, with the last nonempty line the program wrote to standard error.
    case failed(status: Int32, message: String)
    case outputTooLarge
    /// Why decoding failed and how the output began. The toast stays short.
    case invalidOutput(String)
    case configurationRequired

    public var message: String {
        switch self {
        case .launchFailed(let reason): "Couldn’t start the plugin: \(reason)"
        case .timedOut: "The plugin took too long"
        case .cancelled: "Cancelled"
        case .failed(let status, let message): message.isEmpty ? "The plugin failed (exit \(status))" : message
        case .outputTooLarge: "The plugin returned too much data"
        case .invalidOutput: "The plugin returned invalid JSON"
        case .configurationRequired: "Setup required. Configure the plugin in Settings → Plugins."
        }
    }

    /// The message with whatever detail is too long for a toast.
    public var detail: String {
        switch self {
        case .invalidOutput(let reason) where !reason.isEmpty: message + ". " + reason
        default: message
        }
    }
}

/// One run of a plugin's executable. Nothing exists between runs: no helper process,
/// no thread, no timer. A run is a child process whose output arrives through
/// dispatch I/O, so no thread blocks while it works.
public final class PluginRun: @unchecked Sendable {
    public typealias Completion = @Sendable (Result<PluginResponse, PluginRunError>) -> Void
    public typealias ReportCompletion = @Sendable (PluginRunReport) -> Void
    public typealias Rows = @Sendable ([PluginItem]) -> Void

    /// Enough for hundreds of rows; a runaway program is stopped rather than buffered.
    static let maxOutput = 4 * 1024 * 1024
    private static let maxErrorOutput = 16 * 1024

    /// Every field below is touched only on this queue.
    private let queue = DispatchQueue(label: "com.igorv.spotlite.plugin", qos: .userInitiated)
    private let process = Process()
    private var processGroup: pid_t?
    private let completion: ReportCompletion
    private var output = Data()
    /// Bytes read from standard output, kept or not: the limit covers the whole run.
    private var outputBytes = 0
    /// False for a streamed run whose raw output nobody will read: rows are decoded
    /// line by line, so the bytes need not stay in memory.
    private let keepsOutput: Bool
    private var errorOutput = TailBuffer(limit: PluginRun.maxErrorOutput)
    private var started = DispatchTime.now()
    private var outputChannel: DispatchIO?
    private var errorChannel: DispatchIO?
    private var timeout: DispatchSourceTimer?
    private var exitStatus: Int32?
    private var outputEnded = false
    private var errorEnded = false
    private var stopReason: PluginRunError?
    private var finished = false
    /// Set for a streamed run, whose output is decoded line by line as it arrives.
    private var stream: PluginStreamDecoder?
    private let rows: RowMailbox?

    /// Starts `executable` with `arguments`. `completion` is called once, on a
    /// background queue, unless the run is cancelled first.
    @discardableResult
    public static func start(executable: URL, arguments: [String], environment: [String: String],
                             directory: URL, timeout: TimeInterval,
                             completion: @escaping Completion) -> PluginRun {
        startReporting(executable: executable, arguments: arguments, environment: environment,
                       directory: directory, timeout: timeout) { completion($0.result) }
    }

    /// The same run, reporting what the program wrote besides the decoded result.
    ///
    /// With `stream` the output is one JSON object per line (see `PluginStreamDecoder`),
    /// and `rows` receives every row so far on `rowsQueue` as lines arrive. Deliveries
    /// are coalesced: at most one waits on the queue, and it carries the latest rows, so
    /// a burst of lines costs one delivery. The report repeats them all.
    ///
    /// Without `keepsOutput` a streamed run's report has no `output`. A run that is not
    /// streamed always buffers its output, which it decodes at the end.
    @discardableResult
    public static func startReporting(executable: URL, arguments: [String], environment: [String: String],
                                      directory: URL, timeout: TimeInterval, stream: Bool = false,
                                      keepsOutput: Bool = true,
                                      rows: Rows? = nil, rowsQueue: DispatchQueue = .main,
                                      report: @escaping ReportCompletion) -> PluginRun {
        let run = PluginRun(completion: report, stream: stream, keepsOutput: keepsOutput || !stream,
                            rows: stream ? rows.map { RowMailbox(queue: rowsQueue, deliver: $0) } : nil)
        run.queue.async {
            run.launch(executable: executable, arguments: arguments, environment: environment,
                       directory: directory, timeout: timeout)
        }
        return run
    }

    private init(completion: @escaping ReportCompletion, stream: Bool, keepsOutput: Bool, rows: RowMailbox?) {
        self.completion = completion
        self.keepsOutput = keepsOutput
        self.stream = stream ? PluginStreamDecoder() : nil
        self.rows = rows
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
                guard !self.outputEnded || !self.errorEnded else { return }
                // Something the program left running still holds the pipe. Take what
                // was written rather than waiting for a stranger to exit.
                self.queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
                    self.outputChannel?.close(flags: .stop)
                    self.errorChannel?.close(flags: .stop)
                }
            }
        }
        do {
            try process.run()
        } catch {
            finished = true
            // The handler holds this run, and will never be called to let go of it.
            process.terminationHandler = nil
            completion(PluginRunReport(result: .failure(.launchFailed(error.localizedDescription))))
            return
        }
        started = DispatchTime.now()
        // Foundation launches the child in an isolated group on macOS. Record only
        // a confirmed child-owned group so escalation can never target Spotlite's.
        let pid = process.processIdentifier
        if getpgid(pid) == pid, pid != getpgrp() { processGroup = pid }
        // The child has its own copies; ours would keep the pipes from ever ending.
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        outputChannel = read(outputPipe) { [self] chunk, ended in
            // A stopped run reports no output, so what still arrives is not kept.
            if stopReason == nil {
                let remaining = PluginRun.maxOutput - outputBytes
                outputBytes += min(chunk.count, remaining)
                if keepsOutput { output.append(chunk.prefix(remaining)) }
                if chunk.count > remaining { stop(.outputTooLarge) }
                else if stream?.feed(chunk) == true, let items = stream?.items { rows?.post(items) }
            }
            if ended {
                outputEnded = true
                finishIfReady()
            }
        }
        errorChannel = read(errorPipe) { [self] chunk, ended in
            errorOutput.append(chunk)
            if ended {
                errorEnded = true
                finishIfReady()
            }
        }

        // Cancelling a dispatch source removes its deadline immediately, rather
        // than leaving a cancelled asyncAfter item queued until the old timeout.
        let deadline = DispatchSource.makeTimerSource(queue: queue)
        deadline.schedule(deadline: .now() + seconds)
        deadline.setEventHandler { [weak self] in self?.stop(.timedOut) }
        timeout = deadline
        deadline.resume()
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
        if process.isRunning || processGroup != nil {
            if process.isRunning { process.terminate() }
            // A shell may exit on SIGTERM while a nested command ignores it. The
            // entire owned group must be stopped even after its leader has exited.
            let process = process
            let group = processGroup
            queue.asyncAfter(deadline: .now() + .seconds(1)) {
                if let group { kill(-group, SIGKILL) }
                else if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        // A cancelled run reports nothing, so it need not wait for the exit.
        if reason == .cancelled {
            rows?.drop()
            finish()
        }
    }

    private func finishIfReady() {
        // Exit notification and the two I/O streams can arrive in any order. In
        // particular, stdout EOF does not mean the diagnostic on stderr was read.
        if exitStatus != nil, outputEnded, errorEnded { finish() }
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

        let errors = errorOutput.bytes
        // A last line without a newline counts only when the output ended on its own.
        if stopReason == nil { stream?.finish() }
        func report(_ result: Result<PluginResponse, PluginRunError>) {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
            completion(PluginRunReport(result: result, status: exitStatus, output: output,
                                       errorOutput: errors, duration: elapsed,
                                       stream: stream?.summary, streamedItems: stream?.items ?? []))
        }
        if let stopReason {
            if stopReason != .cancelled { report(.failure(stopReason)) }
            return
        }
        let status = exitStatus ?? 0
        guard status == 0 else {
            let line = PluginDiagnostics.summaryLine(PluginDiagnostics.text(errors))
            report(.failure(.failed(status: status, message: line)))
            return
        }
        if let stream {
            var response = stream.response
            response.items = stream.items
            return report(.success(response))
        }
        do {
            report(.success(try PluginResponse.decode(output)))
        } catch {
            report(.failure(.invalidOutput(PluginDiagnostics.invalidOutputDetail(error, output: output))))
        }
    }
}

/// Hands a streamed run's rows to another queue without queueing one delivery per
/// chunk: a delivery already waiting picks up the newer rows instead. Deliveries are
/// at least a frame apart, so a trickle of lines does not redraw the list for each;
/// the first comes at once, and a later one waits out the rest of the frame, one-shot.
private final class RowMailbox: @unchecked Sendable {
    private let queue: DispatchQueue
    private let deliver: PluginRun.Rows
    private let lock = NSLock()
    private var latest: [PluginItem]?
    private var lastDelivery: UInt64 = 0

    static let interval: UInt64 = 16_000_000

    init(queue: DispatchQueue, deliver: @escaping PluginRun.Rows) {
        self.queue = queue
        self.deliver = deliver
    }

    func post(_ items: [PluginItem]) {
        let (waiting, last) = lock.withLock {
            defer { latest = items }
            return (latest != nil, lastDelivery)
        }
        guard !waiting else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let work: @Sendable () -> Void = { [self] in
            let items = lock.withLock { () -> [PluginItem]? in
                defer { latest = nil }
                if latest != nil { lastDelivery = DispatchTime.now().uptimeNanoseconds }
                return latest
            }
            if let items { deliver(items) }
        }
        if last == 0 || now >= last + Self.interval { queue.async(execute: work) }
        else { queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: last + Self.interval), execute: work) }
    }

    /// A cancelled run delivers nothing more, including what is already queued.
    func drop() { lock.withLock { latest = nil } }
}

public enum PluginEnvironment {
    /// A GUI app inherits launchd's short PATH, which has none of the places command
    /// line tools are installed to.
    static let extraPaths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]

    /// The environment a plugin runs in: Spotlite's own, a usable PATH, and the
    /// `SPOTLITE_*` variables that say where the plugin lives, what was typed, and how
    /// it was started.
    public static func make(for plugin: InstalledPlugin, query: String,
                            base: [String: String] = ProcessInfo.processInfo.environment,
                            dataDirectory: URL? = nil, configurationJSON: String = "{}",
                            configurationVariables: [String: String] = [:],
                            command: String? = nil, action: PluginRunAction? = nil,
                            appearance: String? = nil, version: String? = nil) -> [String: String] {
        // Per-field values come only from this plugin's settings, never from whatever
        // Spotlite itself happened to inherit.
        var environment = base.filter { !$0.key.hasPrefix(configurationPrefix) }
        let inherited = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        environment["PATH"] = (inherited + extraPaths.filter { !inherited.contains($0) }).joined(separator: ":")
        environment["SPOTLITE_PLUGIN_ID"] = plugin.id
        environment["SPOTLITE_PLUGIN_DIR"] = plugin.directory.path
        environment["SPOTLITE_PLUGIN_DATA"] = (dataDirectory ?? PluginStore.dataDirectory(for: plugin.id)).path
        environment["SPOTLITE_QUERY"] = query
        environment["SPOTLITE_CONFIG"] = configurationJSON
        environment.merge(configurationVariables) { _, field in field }
        if let command { environment["SPOTLITE_COMMAND"] = command }
        if let action { environment["SPOTLITE_ACTION"] = action.rawValue }
        if let appearance { environment["SPOTLITE_APPEARANCE"] = appearance }
        if let version { environment["SPOTLITE_VERSION"] = version }
        return environment
    }

    static let configurationPrefix = "SPOTLITE_CONFIG_"

    /// `SPOTLITE_CONFIG_<ID>`: the id uppercased, anything outside A-Z and 0-9 as `_`.
    public static func variableName(forSetting id: String) -> String {
        configurationPrefix + String(String.UnicodeScalarView(id.uppercased().unicodeScalars.map {
            ("A"..."Z").contains($0) || ("0"..."9").contains($0) ? $0 : "_"
        }))
    }

    /// One variable per scalar value, for scripts that would rather not parse JSON.
    /// `ids` are the declared fields: when two of them map to one name, neither is
    /// exported, whatever their values, so a name never depends on declaration order.
    /// `SPOTLITE_CONFIG` stays authoritative and always has both.
    public static func configurationVariables(ids: [String], values: [String: PluginSettingValue]) -> [String: String] {
        var claims: [String: Int] = [:]
        for id in ids { claims[variableName(forSetting: id), default: 0] += 1 }
        var variables: [String: String] = [:]
        for id in ids {
            let name = variableName(forSetting: id)
            guard claims[name] == 1, let value = values[id] else { continue }
            // Only plain values have one obvious text form; anything else is JSON only.
            if case .string(let text) = value { variables[name] = text }
            else if case .number = value { variables[name] = value.text }
            else if case .boolean(let flag) = value { variables[name] = flag ? "true" : "false" }
            else { continue }
        }
        return variables
    }
}
