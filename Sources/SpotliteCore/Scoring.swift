import Foundation

/// Weights for the match scorer. Word starts and consecutive letters earn bonuses;
/// match tiers keep a full consecutive run above scattered subsequences.
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
    /// Acronyms or scattered letters from the name or alias.
    case other
    /// The whole query appears consecutively inside the name or alias: "cha" in
    /// Keychain Access beats the scattered letters in T3 Code (Alpha).
    case substring
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
