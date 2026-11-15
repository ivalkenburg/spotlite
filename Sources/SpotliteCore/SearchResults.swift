import Foundation

/// One row of the results list, before the AppKit layer decides how to draw it.
public enum SearchResult {
    /// The expression is kept as typed: the card shows it above the result.
    case calculation(expression: String, value: Double)
    case conversion(expression: String, result: String)
    case app(MatchResult)
    case settings
    case webSearch(query: String, engine: WebSearchEngine)
}

/// Assembles the result list for a query: a calculation pinned on top when the query is
/// arithmetic, then apps and the Settings entry when the query asks for it, ranked together by
/// textual score plus frecency, then the web search. Apps still appear below a
/// calculation, since `x^2` shouldn't hide an app named X.
public enum SearchResults {
    /// Queries that offer the Settings entry alongside any app matches.
    static let settingsKeywords = ["settings", "preferences", "spotlite"]
    /// Launch-history id of the Spotlite Settings row.
    public static let settingsHistoryID = "utility.settings"

    public static func build(
        for query: String,
        corpus: SearchCorpus,
        matcher: Matcher,
        frecency: Frecency,
        previousResult: Double? = nil,
        recents: Int = 0,
        webSearch: WebSearchEngine? = nil,
        webSearchMode: WebSearchMode = .onlyWhenNoLocalResults,
        hiddenUtilities: Set<SearchUtility> = [],
        now: Date = Date()
    ) -> [SearchResult] {
        if query.allSatisfy(\.isWhitespace) {
            return recentEntries(in: corpus, frecency: frecency, limit: recents, now: now).map(SearchResult.app)
        }
        guard let trimmed = bounded(query) else {
            // Too long for the calculator and the matcher, but a pasted error message is
            // just what a web search is for.
            guard webSearchMode != .off, let webSearch,
                  let long = query.boundedTrimmedWhitespace(maximumCount: maxWebQuery) else { return [] }
            return [.webSearch(query: String(long), engine: webSearch)]
        }

        var result: [SearchResult] = []
        if !hiddenUtilities.contains(.unitConversion), let converted = QuickConversion.evaluate(trimmed) {
            result.append(.conversion(expression: trimmed, result: converted))
        } else if !hiddenUtilities.contains(.calculator),
                  let value = Calculator.evaluate(trimmed, previous: previousResult) {
            result.append(.calculation(expression: trimmed, value: value))
        }

        // Unordered: ranking sorts them once, with launch history applied.
        let matches = matcher.matches(trimmed, in: corpus)
        let ranked = AppRanking.rank(matches, frecency: frecency, now: now)
        // The self-indexed escape hatch: reachable even with the menu bar icon hidden.
        if let keyword = matchedKeyword(trimmed) {
            result.append(contentsOf: insertingSettings(into: ranked, keyword: keyword, query: trimmed,
                                                        matcher: matcher, frecency: frecency, now: now))
        } else {
            result.append(contentsOf: ranked.map(SearchResult.app))
        }
        // Last, so it only becomes the top hit when nothing on this Mac matches. Not
        // under a calculation: arithmetic is already answered, and the card would lose
        // its standalone shape to a row nobody wants.
        if let webSearch, webSearchMode != .off, !hasAnswer(result),
           webSearchMode == .always || result.isEmpty {
            result.append(.webSearch(query: trimmed, engine: webSearch))
        }
        return result
    }

    /// One-entry corpora of the keywords, built once, to score a query as a name prefix.
    private static let keywordCorpora: [String: SearchCorpus] = Dictionary(
        uniqueKeysWithValues: settingsKeywords.map { keyword in
            (keyword, SearchCorpus(entries: [AppEntry(url: URL(string: "spotlite-builtin:")!, name: keyword,
                                                      bundleID: keyword, kind: .command)]))
        })

    /// Longer than any typed query, short enough to stay a sane URL.
    static let maxWebQuery = 2_000

    private static func hasAnswer(_ results: [SearchResult]) -> Bool {
        if case .calculation = results.first { return true }
        if case .conversion = results.first { return true }
        return false
    }

    /// Frequently used apps still in the corpus, strongest first. Built only for an
    /// empty query, so the id lookup is not paid per keystroke.
    ///
    /// Apps only: with commands here, the shortcut and Return could lock or restart
    /// the Mac, and panes or links do not belong in the frequently used apps list.
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
            .map { MatchResult(entry: $0.0, score: 0) }
    }

    /// The trimmed query, or nil when it is empty or too long to produce any row: the
    /// calculator and the matcher both reject longer input, and no keyword is that long.
    /// Checked first so a large paste is never copied or lowercased on each keystroke.
    private static func bounded(_ query: String) -> String? {
        query.boundedTrimmedWhitespace(
            maximumCount: max(Calculator.maxInputLength, Matcher.maxSupportedQuery)
        ).map(String.init)
    }

    /// The keyword `trimmed` starts. Two characters minimum, or a bare "s" or "p" would
    /// summon an entry on every search.
    private static func matchedKeyword(_ trimmed: String) -> String? {
        let lowered = trimmed.lowercased()
        guard lowered.count >= 2 else { return nil }
        return settingsKeywords.first { $0.hasPrefix(lowered) }
    }

    /// Places the Settings entry among the ranked apps. It is a name-prefix match with the
    /// score a name starting with the query would earn, and ranks like an app: launch
    /// history lifts it past a never-used app of the same tier. On a tie the app wins, so
    /// an unused entry sits just below the apps it ties with. Scores only the apps before it.
    private static func insertingSettings(into ranked: [MatchResult], keyword: String, query: String,
                                          matcher: Matcher, frecency: Frecency, now: Date) -> [SearchResult] {
        let precedence = MatchTier.namePrefix.rawValue * 2 + 1
        let textual = keywordCorpora[keyword].flatMap { matcher.matches(query, in: $0).first?.score } ?? 0
        let score = frecency.adjustedScore(textual, for: settingsHistoryID, now: now)
        let index = ranked.firstIndex { match in
            let tier = AppRanking.precedence(match)
            return tier < precedence
                || (tier == precedence && frecency.adjustedScore(match.score, for: match.entry.id, now: now) < score)
        } ?? ranked.endIndex
        var rows = ranked.map(SearchResult.app)
        rows.insert(.settings, at: index)
        return rows
    }
}
