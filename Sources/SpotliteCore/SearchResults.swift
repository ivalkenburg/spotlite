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
        corpus: SearchCorpus,
        matcher: Matcher,
        frecency: Frecency,
        previousResult: Double? = nil,
        now: Date = Date()
    ) -> [SearchResult] {
        guard let trimmed = bounded(query) else { return [] }

        var result: [SearchResult] = []
        if let value = Calculator.evaluate(trimmed, previous: previousResult) {
            result.append(.calculation(expression: trimmed, value: value))
        }

        // Unordered: ranking sorts them once, with launch history applied.
        let matches = matcher.matches(trimmed, in: corpus)
        let ranked = AppRanking.rank(matches, frecency: frecency, now: now)
        result.append(contentsOf: ranked.map(SearchResult.app))

        // The self-indexed escape hatch: reachable even with the menu bar icon hidden.
        if mentions(trimmed, keywords: settingsKeywords) { result.append(.settings) }
        if mentions(trimmed, keywords: caffeineKeywords) { result.append(.caffeinate) }
        return result
    }

    /// Whether `query` shows the Caffeinate row, so a caffeine change elsewhere only
    /// rebuilds the list when that row is on screen.
    public static func offersCaffeinate(_ query: String) -> Bool {
        guard let trimmed = bounded(query) else { return false }
        return mentions(trimmed, keywords: caffeineKeywords)
    }

    /// The trimmed query, or nil when it is empty or too long to produce any row: the
    /// calculator and the matcher both reject longer input, and no keyword is that long.
    /// Checked first so a large paste is never copied or lowercased on each keystroke.
    private static func bounded(_ query: String) -> String? {
        query.boundedTrimmedWhitespace(
            maximumCount: max(Calculator.maxInputLength, Matcher.maxSupportedQuery)
        ).map(String.init)
    }

    /// Three characters minimum, or a bare "s" or "p" would summon an entry on every search.
    private static func mentions(_ trimmed: String, keywords: [String]) -> Bool {
        let lowered = trimmed.lowercased()
        return lowered.count >= 3 && keywords.contains { $0.hasPrefix(lowered) }
    }
}
