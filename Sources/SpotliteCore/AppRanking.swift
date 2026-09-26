import Foundation

/// Applies user state after fuzzy matching. Keeping the final limit here ensures hidden
/// entries and the matcher's preliminary ordering cannot discard eligible candidates.
public enum AppRanking {
    public static func rank(
        _ matches: [MatchResult],
        hiddenBundleIDs: Set<String>,
        frecency: Frecency,
        now: Date = Date(),
        limit: Int = 50
    ) -> [MatchResult] {
        guard limit > 0 else { return [] }

        let ranked = matches.compactMap { match -> (MatchResult, Double)? in
            if let bundleID = match.entry.bundleID, hiddenBundleIDs.contains(bundleID) {
                return nil
            }
            return (match, frecency.adjustedScore(match.score, for: match.entry.id, now: now))
        }.sorted { a, b in
            // Launch history reorders apps within a tier, never across tiers.
            if a.0.tier.rawValue != b.0.tier.rawValue { return a.0.tier.rawValue > b.0.tier.rawValue }
            return a.1 != b.1 ? a.1 > b.1 : a.0.entry.tieBreaksBefore(b.0.entry)
        }

        return ranked.prefix(limit).map(\.0)
    }
}
