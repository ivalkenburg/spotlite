import Foundation

/// One row of the results list, before the AppKit layer decides how to draw it.
public enum SearchResult {
    /// The expression is kept as typed: the card shows it above the result.
    case calculation(expression: String, value: Double)
    case app(MatchResult)
    case settings
    case caffeinate
}

/// Assembles the result list for a query: a calculation pinned on top when the query is
/// arithmetic, then apps ranked by textual score plus frecency, then the built-in
/// entries the query asks for. Apps still appear below a calculation, since `x^2`
/// shouldn't hide an app named X.
public enum SearchResults {
    /// Queries that offer the Settings and Caffeinate entries alongside any app matches.
    static let settingsKeywords = ["settings", "preferences", "spotlite"]
    static let caffeineKeywords = ["caffeinate", "caffeine"]

    public static func build(
        for query: String,
        entries: [AppEntry],
        matcher: Matcher,
        aliases: AliasIndex,
        hiddenBundleIDs: Set<String>,
        frecency: Frecency,
        previousResult: Double? = nil,
        now: Date = Date()
    ) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var result: [SearchResult] = []
        if let value = Calculator.evaluate(trimmed, previous: previousResult) {
            result.append(.calculation(expression: trimmed, value: value))
        }

        let matches = matcher.search(trimmed, in: entries, aliases: aliases,
                                     limit: max(1, entries.count))
        let ranked = AppRanking.rank(matches, hiddenBundleIDs: hiddenBundleIDs,
                                     frecency: frecency, now: now)
        result.append(contentsOf: ranked.map(SearchResult.app))

        // The self-indexed escape hatch: reachable even with the menu bar icon hidden.
        if mentions(trimmed, keywords: settingsKeywords) { result.append(.settings) }
        if offersCaffeinate(trimmed) { result.append(.caffeinate) }
        return result
    }

    /// Whether `query` shows the Caffeinate row, so a caffeine change elsewhere only
    /// rebuilds the list when that row is on screen.
    public static func offersCaffeinate(_ query: String) -> Bool {
        mentions(query.trimmingCharacters(in: .whitespaces), keywords: caffeineKeywords)
    }

    /// Three characters minimum, or a bare "s" or "p" would summon an entry on every search.
    private static func mentions(_ trimmed: String, keywords: [String]) -> Bool {
        let lowered = trimmed.lowercased()
        return lowered.count >= 3 && keywords.contains { $0.hasPrefix(lowered) }
    }
}
