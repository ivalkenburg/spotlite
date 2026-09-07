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
            if a.1 != b.1 { return a.1 > b.1 }
            if a.0.entry.lowerChars.count != b.0.entry.lowerChars.count {
                return a.0.entry.lowerChars.count < b.0.entry.lowerChars.count
            }
            if a.0.entry.name != b.0.entry.name { return a.0.entry.name < b.0.entry.name }
            return a.0.entry.instanceID < b.0.entry.instanceID
        }

        return ranked.prefix(limit).map(\.0)
    }
}
