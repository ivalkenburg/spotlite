import Foundation

/// Weights for the match scorer. Tuned so that a word-start match always beats a
/// mid-word one, and a consecutive run always beats a scattered subsequence.
public enum Scoring {
    public static let match = 16
    public static let bonusBoundary = 30
    public static let bonusCamel = 20
    public static let bonusConsecutive = 12
    /// The first query character carries extra weight: matching the start of a name
    /// is far more meaningful than matching its middle.
    public static let firstCharMultiplier = 2
    public static let gapStart = -3
    public static let gapExtension = -1
    /// Characters skipped *before* the first match are charged too. Without this a
    /// word-start deep inside a name ("Keychain **A**ccess") scores identically to a
    /// name-start match ("**A**ffinity"), which is plainly wrong for a launcher.
    /// Capped so a long name is penalised, not disqualified.
    public static let maxLeadingPenalty = -20
}

/// Which kind of match a result is. Tiers rank strictly above one another; the score,
/// launch history and tie-breaks only order results within a tier.
public enum MatchTier: Int, Sendable {
    /// Word starts, acronyms, scattered letters, or letters from inside an alias.
    case other
    /// The query is the start of the name: "gh" reaches Ghostty before the acronym
    /// "GitHub Desktop", as in Spotlight.
    case namePrefix
    /// The query is the start of an alias. An alias is an explicit instruction from the
    /// user, so "ps" reaches Photoshop, not Passwords.
    case aliasPrefix
}

public struct MatchResult: Sendable {
    public let entry: AppEntry
    public let score: Int
    /// Indices into the entry's name of the matched characters, for highlighting.
    public let positions: [Int]
    public let tier: MatchTier

    init(entry: AppEntry, score: Int, positions: [Int], tier: MatchTier = .other) {
        self.entry = entry
        self.score = score
        self.positions = positions
        self.tier = tier
    }
}
