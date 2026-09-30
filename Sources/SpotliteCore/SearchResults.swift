import Foundation

/// One row of the results list, before the AppKit layer decides how to draw it.
public enum SearchResult {
    /// The expression is kept as typed: the card shows it above the result.
    case calculation(expression: String, value: Double)
    case conversion(expression: String, result: String)
    case generateUUID
    case app(MatchResult)
    case settings
    case caffeinate
    case webSearch(query: String, engine: WebSearchEngine)
}

/// Assembles the result list for a query: a calculation pinned on top when the query is
/// arithmetic, then apps ranked by textual score plus frecency, then the built-in
/// entries the query asks for, then the web search. Apps still appear below a
/// calculation, since `x^2` shouldn't hide an app named X.
public enum SearchResults {
    /// Queries that offer built-in entries alongside any app matches.
    static let settingsKeywords = ["settings", "preferences", "spotlite"]
    static let uuidKeywords = ["uuid", "generate uuid"]
    static let caffeineKeywords = ["caffeinate", "caffeine"]

    public static func build(
        for query: String,
        corpus: SearchCorpus,
        matcher: Matcher,
        frecency: Frecency,
        previousResult: Double? = nil,
        recents: Int = 0,
        webSearch: WebSearchEngine? = nil,
        now: Date = Date()
    ) -> [SearchResult] {
        if query.allSatisfy(\.isWhitespace) {
            return recentEntries(in: corpus, frecency: frecency, limit: recents, now: now).map(SearchResult.app)
        }
        guard let trimmed = bounded(query) else {
            // Too long for the calculator and the matcher, but a pasted error message is
            // just what a web search is for.
            guard let webSearch,
                  let long = query.boundedTrimmedWhitespace(maximumCount: maxWebQuery) else { return [] }
            return [.webSearch(query: String(long), engine: webSearch)]
        }

        var result: [SearchResult] = []
        if let converted = QuickConversion.evaluate(trimmed) {
            result.append(.conversion(expression: trimmed, result: converted))
        } else if let value = Calculator.evaluate(trimmed, previous: previousResult) {
            result.append(.calculation(expression: trimmed, value: value))
        }

        // Unordered: ranking sorts them once, with launch history applied.
        let matches = matcher.matches(trimmed, in: corpus)
        let ranked = AppRanking.rank(matches, frecency: frecency, now: now)
        result.append(contentsOf: ranked.map(SearchResult.app))

        // The self-indexed escape hatch: reachable even with the menu bar icon hidden.
        if mentions(trimmed, keywords: settingsKeywords) { result.append(.settings) }
        if mentions(trimmed, keywords: caffeineKeywords) { result.append(.caffeinate) }
        if mentions(trimmed, keywords: uuidKeywords) { result.append(.generateUUID) }
        // Last, so it only becomes the top hit when nothing on this Mac matches. Not
        // under a calculation: arithmetic is already answered, and the card would lose
        // its standalone shape to a row nobody wants.
        if let webSearch, !hasAnswer(result) {
            result.append(.webSearch(query: trimmed, engine: webSearch))
        }
        return result
    }

    /// Longer than any typed query, short enough to stay a sane URL.
    static let maxWebQuery = 2_000

    private static func hasAnswer(_ results: [SearchResult]) -> Bool {
        if case .calculation = results.first { return true }
        if case .conversion = results.first { return true }
        return false
    }

    /// The most-launched apps still in the corpus, strongest first. Built only for an
    /// empty query, so the id lookup is not paid per keystroke.
    ///
    /// Apps only: with commands here, the shortcut and Return could lock or restart
    /// the Mac, and panes or links are not what "recent apps" promises.
    static func recentEntries(in corpus: SearchCorpus, frecency: Frecency, limit: Int,
                              now: Date = Date()) -> [MatchResult] {
        guard limit > 0, !frecency.records.isEmpty else { return [] }
        // The first copy of an app stands for its id, as launch history is shared.
        var byID: [String: AppEntry] = [:]
        for entry in corpus.entries where entry.kind == .app && byID[entry.id] == nil { byID[entry.id] = entry }
        return frecency.records.keys
            .compactMap { id in byID[id].map { ($0, frecency.multiplier(for: id, now: now)) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.tieBreaksBefore($1.0) }
            .prefix(limit)
            .map { MatchResult(entry: $0.0, score: 0, positions: []) }
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
