import Foundation
import Testing
@testable import SpotliteCore

@Suite("Search results")
struct SearchResultsTests {
    private let entries = ["Safari", "Calculator", "Settings Sync", "X"].map { name in
        AppEntry(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name,
                 bundleID: "app.\(name.lowercased().replacingOccurrences(of: " ", with: "."))")
    }

    private func build(_ query: String, hidden: Set<String> = [], frecency: Frecency = Frecency(),
                       recents: Int = 0, web: WebSearchEngine? = nil,
                       mode: WebSearchMode = .always,
                       hiddenUtilities: Set<SearchUtility> = []) -> [SearchResult] {
        SearchResults.build(for: query, corpus: SearchCorpus(entries: entries, hiddenBundleIDs: hidden),
                            matcher: Matcher(), frecency: frecency, recents: recents, webSearch: web,
                            webSearchMode: mode,
                            hiddenUtilities: hiddenUtilities)
    }

    private func describe(_ results: [SearchResult]) -> [String] {
        results.map {
            switch $0 {
            case .calculation(_, let value): return "= \(value)"
            case .app(let match): return match.entry.name
            case .conversion(_, let result): return result
            case .settings: return "settings"
            case .webSearch(let query, let engine): return "\(engine.name): \(query)"
            }
        }
    }

    @Test func emptyQueryHasNoResults() {
        #expect(build("   ").isEmpty)
    }

    @Test func oversizedQueryHasNoResults() {
        #expect(build(" " + String(repeating: "1+", count: 200) + "1 ").isEmpty)
        #expect(build(String(repeating: "s", count: 10_000)).isEmpty)
    }

    @Test func calculationIsPinnedOnTop() {
        #expect(describe(build("2^3")) == ["= 8.0"])
    }

    @Test func settingsFollowsAppMatches() {
        #expect(describe(build("sett")) == ["Settings Sync", "settings"])
    }

    @Test func builtInEntriesNeedTwoCharacters() {
        #expect(!describe(build("s")).contains("settings"))
        #expect(describe(build("se")).contains("settings"))
    }

    @Test func settingsRanksByItsOwnHistory() {
        #expect(describe(build("se")) == ["Settings Sync", "settings"])
        var frecency = Frecency()
        frecency.recordLaunch(SearchResults.settingsHistoryID)
        #expect(describe(build("se", frecency: frecency)) == ["settings", "Settings Sync"])
        // An app with more history still wins the tier.
        for _ in 0..<3 { frecency.recordLaunch("app.settings.sync") }
        #expect(describe(build("se", frecency: frecency)) == ["Settings Sync", "settings"])
    }

    @Test func historyNeverLiftsABuiltInAboveAnAliasMatch() {
        var frecency = Frecency()
        for _ in 0..<30 { frecency.recordLaunch(SearchResults.settingsHistoryID) }
        let corpus = SearchCorpus(entries: entries, aliases: AliasIndex(aliases: ["app.safari": "spo"]))
        let results = SearchResults.build(for: "spo", corpus: corpus, matcher: Matcher(), frecency: frecency)
        #expect(describe(results) == ["Safari", "settings"])
    }

    @Test func settingsHistoryIDCannotBeAnAppID() {
        #expect(!entries.contains { $0.id == SearchResults.settingsHistoryID })
    }

    @Test func twoCharactersReachEachKeyword() {
        #expect(describe(build("sp")) == ["settings"])
        #expect(describe(build("pr")) == ["settings"])
    }

    @Test func builtInsOutrankLowerTiersAndNonAppsOfTheSameTier() {
        let pane = AppEntry(url: URL(fileURLWithPath: "/tmp/Security"), name: "Security",
                            bundleID: "pane.security", kind: .settingsPane)
        let corpus = SearchCorpus(entries: entries + [pane, AppEntry(
            url: URL(fileURLWithPath: "/Applications/Raise.app"), name: "Raise", bundleID: "app.raise")])
        var frecency = Frecency()
        for _ in 0..<30 { frecency.recordLaunch(pane.id) }
        // Equal tier: the app, then the unused built-in, then the pane with plenty of history
        // (a pane ranks just below an app of its tier), then the substring match.
        let results = SearchResults.build(for: "se", corpus: corpus, matcher: Matcher(), frecency: frecency)
        #expect(describe(results) == ["Settings Sync", "settings", "Security", "Raise"])
    }

    @Test func builtInIsNotCutOffByTheRowLimit() {
        let many = (0..<80).map { index in
            AppEntry(url: URL(fileURLWithPath: "/Applications/Set\(index).app"), name: "Set\(index)",
                     bundleID: "app.set\(index)")
        }
        let corpus = SearchCorpus(entries: many)
        let unused = SearchResults.build(for: "se", corpus: corpus, matcher: Matcher(), frecency: Frecency())
        #expect(describe(unused).count == 51)
        #expect(describe(unused).contains("settings"))
        var frecency = Frecency()
        frecency.recordLaunch(SearchResults.settingsHistoryID)
        let used = SearchResults.build(for: "se", corpus: corpus, matcher: Matcher(), frecency: frecency)
        #expect(describe(used).first == "settings")
    }

    @Test func builtInsCountAsLocalResultsForWebSearchFallback() {
        for query in ["se", "sp", "pr"] {
            let results = build(query, web: .google, mode: .onlyWhenNoLocalResults)
            #expect(!describe(results).contains { $0.hasPrefix("Google:") })
            #expect(describe(build(query, web: .google, mode: .always)).last == "Google: \(query)")
        }
    }

    @Test func recentsIgnoreUtilityHistory() {
        var frecency = Frecency()
        for _ in 0..<5 { frecency.recordLaunch(SearchResults.settingsHistoryID) }
        #expect(build("", frecency: frecency, recents: 5).isEmpty)
        frecency.recordLaunch("app.safari")
        #expect(describe(build("", frecency: frecency, recents: 5)) == ["Safari"])
    }

    @Test func hiddenAppsAreLeftOut() {
        #expect(!describe(build("saf", hidden: ["app.safari"])).contains("Safari"))
    }

    @Test func emptyQueryListsMostLaunchedFirst() {
        let now = Date()
        var frecency = Frecency()
        for _ in 0..<5 { frecency.recordLaunch("app.x", now: now) }
        frecency.recordLaunch("app.safari", now: now)
        frecency.recordLaunch("app.gone", now: now)
        frecency.recordLaunch("app.calculator", now: now)
        // Equal history breaks ties as ranking does: the shorter name first.
        #expect(describe(build("", frecency: frecency, recents: 2)) == ["X", "Safari"])
        #expect(describe(build(" ", frecency: frecency, recents: 9)) == ["X", "Safari", "Calculator"])
        // Hidden apps stay hidden, and the setting off means an empty panel as before.
        #expect(!describe(build("", hidden: ["app.x"], frecency: frecency, recents: 9)).contains("X"))
        #expect(build("", frecency: frecency).isEmpty)
    }

    /// Hotkey then Return must never lock or restart the Mac.
    @Test func recentsAreAppsOnly() throws {
        let link = try #require(Link(name: "Downloads", target: "/tmp").entry)
        let corpus = SearchCorpus(entries: entries + SystemCommand.entries + [link])
        var frecency = Frecency()
        for _ in 0..<9 { frecency.recordLaunch(SystemCommand.lockScreen.id) }
        frecency.recordLaunch(link.id)
        frecency.recordLaunch("app.safari")
        let recents = SearchResults.recentEntries(in: corpus, frecency: frecency, limit: 5)
        #expect(recents.map(\.entry.name) == ["Safari"])
    }

    @Test func calculationGetsNoWebSearch() {
        #expect(describe(build("2+2", web: .google)) == ["= 4.0"])
    }

    /// Too long to match, but exactly what a pasted error message wants.
    @Test func overlongQueryStillOffersWebSearch() {
        let pasted = String(repeating: "error ", count: 100)
        #expect(describe(build(pasted, web: .google)).count == 1)
        #expect(build(pasted).isEmpty)
        #expect(build(String(repeating: "x", count: SearchResults.maxWebQuery + 1), web: .google).isEmpty)
    }

    @Test func webSearchComesLastAndLeadsWhenNothingMatches() {
        #expect(describe(build(" saf ", web: .google)) == ["Safari", "Google: saf"])
        #expect(describe(build("zzq", web: .bing)) == ["Bing: zzq"])
        #expect(build("", web: .google).isEmpty)
    }

    @Test func fallbackWebSearchWaitsUntilEveryLocalResultIsAbsent() {
        for query in ["saf", "sett", "2+2", "10 km to miles"] {
            let results = build(query, web: .google, mode: .onlyWhenNoLocalResults)
            #expect(!results.isEmpty)
            #expect(!describe(results).contains { $0.hasPrefix("Google:") })
        }
        #expect(describe(build("zzq", web: .google, mode: .onlyWhenNoLocalResults)) == ["Google: zzq"])
        #expect(describe(build("saf", hidden: ["app.safari"], web: .google,
                               mode: .onlyWhenNoLocalResults)) == ["Google: saf"])
    }

    @Test(arguments: [EntryKind.app, .settingsPane, .command, .link])
    func everyIndexedKindCountsAsLocal(_ kind: EntryKind) {
        let entry = AppEntry(url: URL(fileURLWithPath: "/tmp/Local"), name: "Local", bundleID: "local", kind: kind)
        let results = SearchResults.build(for: "loc", corpus: SearchCorpus(entries: [entry]),
                                          matcher: Matcher(), frecency: Frecency(), webSearch: .google,
                                          webSearchMode: .onlyWhenNoLocalResults)
        #expect(describe(results) == ["Local"])
    }

    @Test(arguments: WebSearchMode.allCases)
    func answersAndEmptyQueriesNeverOfferWebSearch(_ mode: WebSearchMode) {
        #expect(describe(build("2+2", web: .google, mode: mode)) == ["= 4.0"])
        #expect(describe(build("10 km to miles", web: .google, mode: mode)).count == 1)
        #expect(build("  ", web: .google, mode: mode).isEmpty)
    }

    @Test func offSuppressesWebSearchIncludingOversizedQueries() {
        #expect(build("zzq", web: .google, mode: .off).isEmpty)
        let pasted = String(repeating: "error ", count: 100)
        #expect(build(pasted, web: .google, mode: .off).isEmpty)
        #expect(describe(build(pasted, web: .google, mode: .onlyWhenNoLocalResults)).count == 1)
    }

    @Test(arguments: SearchUtility.allCases)
    func utilityVisibilityIsIndependent(_ utility: SearchUtility) {
        let query = switch utility {
        case .calculator: "2+2"
        case .unitConversion: "10 km to miles"
        }
        #expect(!build(query).isEmpty)
        #expect(build(query, hiddenUtilities: [utility]).isEmpty)
        let others = Set(SearchUtility.allCases).subtracting([utility])
        #expect(describe(build(query, hiddenUtilities: others)) == describe(build(query)))
    }

    @Test func hidingUtilitiesPreservesAppsSettingsAndWebSearch() {
        let hidden = Set(SearchUtility.allCases)
        #expect(describe(build("calc", hiddenUtilities: hidden)) == ["Calculator"])
        #expect(describe(build("sett", hiddenUtilities: hidden)) == ["Settings Sync", "settings"])
        #expect(describe(build("2+2", web: .google, hiddenUtilities: hidden)) == ["Google: 2+2"])
    }

    @Test func aLineBreakPastedAroundAQueryIsIgnored() {
        #expect(describe(build("safari\n")).first == "Safari")
        #expect(describe(build(" spotlite\n")) == ["settings"])
    }

    @Test func ansReachesTheCalculator() {
        let results = SearchResults.build(for: "ans*2", corpus: .empty, matcher: Matcher(),
                                          frecency: Frecency(), previousResult: 21)
        #expect(describe(results) == ["= 42.0"])
    }

    @Test func hidingTheCalculatorLeavesTheRestOfTheList() {
        #expect(describe(build("sqrt(4)+x", web: .google)) == ["Google: sqrt(4)+x"])
        #expect(describe(build("1+1", hiddenUtilities: [.calculator])).isEmpty)
        #expect(describe(build("1+1")) == ["= 2.0"])
    }

    @Test func hidingConversionDoesNotFallThroughToTheCalculator() {
        #expect(describe(build("255 to hex", hiddenUtilities: [.unitConversion])).isEmpty)
    }

    @Test func recentsStopAtTheirLimitAndAskForNothingWithoutHistory() {
        var frecency = Frecency()
        for entry in entries { frecency.recordLaunch(entry.id) }
        #expect(build("", frecency: frecency, recents: 2).count == 2)
        #expect(build("", frecency: frecency, recents: 0).isEmpty)
        #expect(build("", recents: 5).isEmpty)
    }

    @Test func anOverlongQueryIsTrimmedAndCappedForTheWeb() {
        let tooLong = String(repeating: "a", count: SearchResults.maxWebQuery + 1)
        #expect(build(tooLong, web: .google).isEmpty)
    }
}
