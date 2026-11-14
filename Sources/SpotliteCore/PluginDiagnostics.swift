import Foundation

/// Which kind of action started the executable, passed to it as `SPOTLITE_ACTION`.
public enum PluginRunAction: String, Sendable, CaseIterable {
    case run, list, search

    public init?(_ action: PluginAction) {
        switch action {
        case .run: self = .run
        case .list: self = .list
        case .search: self = .search
        case .open, .copy, .menu: return nil
        }
    }
}

/// The last `limit` bytes written to a stream. A script under `set -e` or a traceback
/// puts the useful line last, so the end is what is worth keeping.
struct TailBuffer {
    let limit: Int
    private var data = Data()

    init(limit: Int) { self.limit = limit }

    mutating func append(_ chunk: Data) {
        data.append(chunk)
        // Trimming only past twice the limit keeps appends amortized and bounded.
        if data.count > limit * 2 { data = Data(data.suffix(limit)) }
    }

    var bytes: Data { data.count > limit ? Data(data.suffix(limit)) : data }
}

/// Everything a finished run produced, for diagnostics. The normal path reads only
/// `result`; the rest is what the program wrote, kept as it was.
public struct PluginRunReport: Sendable {
    public let result: Result<PluginResponse, PluginRunError>
    /// Nil when the program never exited on its own account, as when it failed to start.
    public let status: Int32?
    /// Standard output, up to the run's limit.
    public let output: Data
    /// The tail of standard error.
    public let errorOutput: Data
    public let duration: TimeInterval

    public init(result: Result<PluginResponse, PluginRunError>, status: Int32? = nil, output: Data = Data(),
                errorOutput: Data = Data(), duration: TimeInterval = 0) {
        self.result = result
        self.status = status
        self.output = output
        self.errorOutput = errorOutput
        self.duration = duration
    }

    public var errorText: String { PluginDiagnostics.text(errorOutput) }
}

/// The last run of a plugin, kept in memory for Settings. Small and bounded: the tail
/// of standard error and the start of standard output, never the whole response.
public struct PluginRunRecord: Sendable, Equatable {
    public let date: Date
    public let commandID: String
    public let action: PluginRunAction
    public let arguments: [String]
    public let status: Int32?
    public let error: PluginRunError?
    public let duration: TimeInterval
    public let errorOutput: String
    public let outputExcerpt: String

    static let outputExcerptBytes = 400

    public init(report: PluginRunReport, commandID: String, action: PluginRunAction, arguments: [String],
                date: Date = Date()) {
        self.date = date
        self.commandID = commandID
        self.action = action
        self.arguments = arguments
        self.status = report.status
        if case .failure(let error) = report.result { self.error = error } else { self.error = nil }
        self.duration = report.duration
        self.errorOutput = report.errorText
        self.outputExcerpt = PluginDiagnostics.excerpt(report.output, bytes: Self.outputExcerptBytes)
    }

    public var failed: Bool { error != nil }

    /// Plain lines for a selectable text view. The date is left to the caller to format.
    public var details: String {
        var lines = ["\(commandID.isEmpty ? "?" : commandID) · \(action.rawValue)"
            + (arguments.isEmpty ? "" : " · " + arguments.map(PluginDiagnostics.quoted).joined(separator: " "))]
        lines.append([status.map { "exit \($0)" }, PluginDiagnostics.duration(duration)]
            .compactMap { $0 }.joined(separator: " · "))
        if let error { lines.append("Error: " + error.detail) }
        if !errorOutput.isEmpty { lines += ["", "stderr:", errorOutput.trimmingCharacters(in: .newlines)] }
        if !outputExcerpt.isEmpty { lines += ["", "stdout:", outputExcerpt.trimmingCharacters(in: .newlines)] }
        return lines.joined(separator: "\n")
    }
}

public enum PluginDiagnostics {
    /// Text of a tail that may begin in the middle of a UTF-8 sequence.
    static func text(_ data: Data) -> String {
        String(decoding: data.drop { $0 & 0xC0 == 0x80 }, as: UTF8.self)
    }

    /// The start of `data`, cut on a character boundary, with an ellipsis when cut.
    public static func excerpt(_ data: Data, bytes: Int) -> String {
        guard data.count > bytes else { return String(decoding: data, as: UTF8.self) }
        var text = String(decoding: data.prefix(bytes), as: UTF8.self)
        // A sequence cut in half decodes as a replacement character; drop it.
        if text.hasSuffix("\u{FFFD}") { text.removeLast() }
        return text + "…"
    }

    /// One line for a toast: the last nonempty line of standard error, which is where a
    /// traceback or a `set -e` script leaves the error that stopped it.
    static func summaryLine(_ text: String, limit: Int = 200) -> String {
        let line = text.split(whereSeparator: \.isNewline).reversed()
            .first { !$0.allSatisfy(\.isWhitespace) }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    /// Why a response was not accepted, with how it began, for a plugin author to act on.
    static func invalidOutputDetail(_ error: Error, output: Data) -> String {
        var reason: String
        switch error as? DecodingError {
        case .dataCorrupted(let context):
            reason = context.debugDescription
            // JSONDecoder's own wording is generic; the underlying error says where.
            if let underlying = context.underlyingError as NSError?,
               let where_ = underlying.userInfo[NSDebugDescriptionErrorKey] as? String {
                reason += " " + where_
            }
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            reason = (context.codingPath.map(\.stringValue) + [context.debugDescription]).joined(separator: ": ")
        case .keyNotFound(let key, _): reason = "Missing “\(key.stringValue)”."
        default: reason = String(describing: error)
        }
        let start = excerpt(output, bytes: 200)
        return start.isEmpty ? reason : reason + "\nOutput began: " + start
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.2f s", seconds)
    }

    static func quoted(_ argument: String) -> String {
        argument.isEmpty || argument.contains(where: { $0.isWhitespace || $0 == "\"" }) ? "“\(argument)”" : argument
    }

    /// Standard output as a person reads it: indented if it is JSON, as written if not.
    public static func formatted(_ output: Data, limit: Int = 256 * 1024) -> String {
        if output.count <= limit,
           let object = try? JSONSerialization.jsonObject(with: output, options: [.fragmentsAllowed]),
           let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) {
            return String(decoding: pretty, as: UTF8.self)
        }
        return excerpt(output, bytes: limit)
    }

    /// What Spotlite understood from a response, in one line.
    public static func summary(of response: PluginResponse) -> String {
        var parts: [String] = []
        if let items = response.items { parts.append(items.count == 1 ? "1 item" : "\(items.count) items") }
        if response.toast != nil { parts.append("toast") }
        if response.copy != nil { parts.append("copy") }
        if response.open != nil { parts.append("open") }
        if !response.update.isEmpty { parts.append(response.update.count == 1 ? "1 update" : "\(response.update.count) updates") }
        return parts.isEmpty ? "Valid response, nothing to apply" : "Valid response: " + parts.joined(separator: ", ")
    }
}
