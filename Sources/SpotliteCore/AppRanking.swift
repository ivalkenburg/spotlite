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

        let ranked = matches.map { match in
            (match, frecency.adjustedScore(match.score, for: match.entry.id, now: now), precedence(match))
        }.sorted { a, b in
            // Launch history reorders apps within a tier, never across tiers.
            if a.2 != b.2 { return a.2 > b.2 }
            return a.1 != b.1 ? a.1 > b.1 : a.0.entry.tieBreaksBefore(b.0.entry)
        }

        return ranked.prefix(limit).map(\.0)
    }

    /// Tiers, with a settings pane just below an app of the same tier. A launcher is for
    /// apps first, but "home" should reach the Home pane before Google cHrOMe's scattered
    /// letters. An alias is the top tier, and a pane's counts as much as an app's: the
    /// user asked for it by name.
    private static func precedence(_ match: MatchResult) -> Int {
        let appFirst = match.entry.kind == .app || match.tier == .aliasPrefix
        return match.tier.rawValue * 2 + (appFirst ? 1 : 0)
    }
}
