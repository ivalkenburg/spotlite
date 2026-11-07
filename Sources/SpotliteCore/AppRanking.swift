import Foundation

/// Applies launch history after fuzzy matching. Hidden entries never reach here: the
/// corpus drops them before any scoring.
public enum AppRanking {
    public static func rank(
        _ matches: [MatchResult],
        frecency: Frecency,
        now: Date = Date(),
        limit: Int = 50
    ) -> [MatchResult] {
        guard limit > 0 else { return [] }

        // Sorts small keys, not the matches: each carries a whole entry, so moving and
        // copying them through the sort cost more than the comparisons.
        let ranked = matches.indices.map { index in
            let match = matches[index]
            return (index: index, score: frecency.adjustedScore(match.score, for: match.entry.id, now: now),
                    precedence: precedence(match))
        }.sorted { a, b in
            // Launch history reorders apps within a tier, never across tiers.
            if a.precedence != b.precedence { return a.precedence > b.precedence }
            return a.score != b.score ? a.score > b.score
                : matches[a.index].entry.tieBreaksBefore(matches[b.index].entry)
        }

        return ranked.prefix(limit).map { matches[$0.index] }
    }

    /// Tiers, with a settings pane or command just below an app of the same tier. A
    /// launcher is for apps first, but "home" should reach the Home pane before Google
    /// cHrOMe's scattered letters. An alias is the top tier, and a pane's counts as much
    /// as an app's: the user asked for it by name. So does a link, which the user made.
    static func precedence(_ match: MatchResult) -> Int {
        let kind = match.entry.kind
        let appFirst = kind == .app || kind == .link || match.tier == .aliasPrefix
        return match.tier.rawValue * 2 + (appFirst ? 1 : 0)
    }
}
