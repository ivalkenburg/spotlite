import Foundation

/// Decodes a streamed response as it arrives: one JSON object per line. A line with a
/// `title` is a row. Any other object is a response whose `items` are more rows and
/// whose `toast`, `copy`, `open` and `update` apply when the run ends. A line that is
/// not a JSON object, or a row with keys of the wrong type, is skipped on its own.
///
/// Fed with the run's output chunks on the run's queue; nothing here schedules work.
public struct PluginStreamDecoder {
    /// Every row so far, at most `PluginItem.maxItems`.
    public private(set) var items: [PluginItem] = []
    /// The response lines' other fields, merged: the last toast, copy and open win, and
    /// updates accumulate. `items` is left nil; the rows are above.
    public private(set) var response = PluginResponse()
    /// Lines that could not be used, with why for the first few.
    public private(set) var skipped = 0
    public private(set) var errors: [String] = []

    /// A line cut by a chunk boundary, waiting for the rest.
    private var partial = Data()
    private var line = 0
    private let decoder = JSONDecoder()

    static let maxErrors = 20

    public init() {}

    /// Decodes every complete line in `chunk`. Returns whether rows were added.
    @discardableResult
    public mutating func feed(_ chunk: Data) -> Bool {
        let before = items.count
        var start = chunk.startIndex
        // Only the new bytes are searched, so a long line arriving in many chunks is
        // scanned once.
        while let newline = chunk[start...].firstIndex(of: 0x0A) {
            if partial.isEmpty {
                decode(chunk[start..<newline])
            } else {
                partial.append(chunk[start..<newline])
                decode(partial)
                partial = Data()
            }
            start = chunk.index(after: newline)
        }
        if start < chunk.endIndex { partial.append(chunk[start...]) }
        return items.count > before
    }

    /// Decodes a last line that has no newline. Returns whether rows were added.
    @discardableResult
    public mutating func finish() -> Bool {
        guard !partial.isEmpty else { return false }
        let before = items.count
        decode(partial)
        partial = Data()
        return items.count > before
    }

    public var summary: PluginStreamSummary {
        PluginStreamSummary(rows: items.count, skipped: skipped, errors: errors)
    }

    private var isFull: Bool { items.count >= PluginItem.maxItems }

    private mutating func decode(_ bytes: Data) {
        line += 1
        // A CRLF line's CR is JSON whitespace, so it needs no stripping.
        guard !bytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) else { return }
        // Past the cap rows are still told apart from response lines, but not built.
        decoder.userInfo[StreamLine.remainingRows] = PluginItem.maxItems - items.count
        do {
            switch try decoder.decode(StreamLine.self, from: bytes) {
            case .item(let item): if let item, !isFull { items.append(item) }
            case .response(let line):
                if let rows = line.items, !isFull { items += rows.prefix(PluginItem.maxItems - items.count) }
                if let toast = line.toast { response.toast = toast }
                if let copy = line.copy { response.copy = copy }
                if let open = line.open { response.open = open }
                response.update += line.update
            }
        } catch {
            skipped += 1
            guard errors.count < Self.maxErrors else { return }
            let start = PluginDiagnostics.excerpt(bytes, bytes: 60)
            errors.append("Line \(line): \(PluginDiagnostics.reason(for: error)) (\(start))")
        }
    }
}

/// What a streamed run produced, beside its rows: how many came and which lines did not.
public struct PluginStreamSummary: Sendable, Equatable {
    public let rows: Int
    public let skipped: Int
    /// Why lines were skipped, for the first few.
    public let errors: [String]

    public init(rows: Int, skipped: Int = 0, errors: [String] = []) {
        self.rows = rows
        self.skipped = skipped
        self.errors = errors
    }

    /// One line, as the debug runner and the last-run record say it.
    public var text: String {
        var text = "Streamed " + (rows == 1 ? "1 row" : "\(rows) rows")
        if skipped > 0 { text += ", skipped " + (skipped == 1 ? "1 line" : "\(skipped) lines") }
        return text
    }
}

private enum StreamLine: Decodable {
    /// Nil past the row cap, where a row is recognised but not decoded.
    case item(PluginItem?)
    case response(PluginResponse)

    static let remainingRows = CodingUserInfoKey(rawValue: "remainingRows")!

    private enum CodingKeys: String, CodingKey { case title }

    init(from decoder: Decoder) throws {
        // Throws for anything but an object, as a line must be one.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let remaining = decoder.userInfo[Self.remainingRows] as? Int ?? PluginItem.maxItems
        if c.contains(.title) {
            self = .item(remaining == 0 ? nil : try PluginItem(from: decoder))
        } else {
            self = .response(try PluginResponse(from: decoder, itemLimit: remaining))
        }
    }
}
