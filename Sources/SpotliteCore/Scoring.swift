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
    /// Added to an alias match. An alias is an explicit instruction from the user, so it
    /// must beat an incidental name match — "ps" should reach Photoshop, not Passwords.
    public static let bonusAlias = 60
}

public struct MatchResult: Sendable {
    public let entry: AppEntry
    public let score: Int
    /// Indices into the entry's name of the matched characters, for highlighting.
    public let positions: [Int]
}
