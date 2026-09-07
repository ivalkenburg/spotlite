import Foundation

/// Lowercased alias text, prepared for the matcher.
///
/// Built once whenever preferences change rather than per keystroke: the matcher must
/// not lowercase or allocate while scoring, which is the same reason `AppEntry`
/// precomputes its own character data.
public struct AliasIndex: Sendable {
    public struct Prepared: Sendable {
        public let chars: [Character]
        /// Every alias character is treated as a word start: an alias is chosen by the
        /// user, so there are no incidental letters in it to discount.
        public let bonus: [Int]
    }

    private let prepared: [String: Prepared]
    public let maxLength: Int

    public static let empty = AliasIndex(aliases: [:])

    public init(aliases: [String: String]) {
        var built: [String: Prepared] = [:]
        var longest = 0
        built.reserveCapacity(aliases.count)
        for (id, alias) in aliases {
            let trimmed = alias.trimmingCharacters(in: .whitespaces).lowercased()
            guard !trimmed.isEmpty else { continue }
            let chars = Array(trimmed)
            longest = max(longest, chars.count)
            built[id] = Prepared(chars: chars,
                                 bonus: Array(repeating: Scoring.bonusBoundary, count: chars.count))
        }
        prepared = built
        maxLength = longest
    }

    public subscript(id: String) -> Prepared? { prepared[id] }
    public var isEmpty: Bool { prepared.isEmpty }
}
