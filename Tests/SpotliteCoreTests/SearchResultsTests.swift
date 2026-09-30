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
                       recents: Int = 0, web: WebSearchEngine? = nil) -> [SearchResult] {
        SearchResults.build(for: query, corpus: SearchCorpus(entries: entries, hiddenBundleIDs: hidden),
                            matcher: Matcher(), frecency: frecency, recents: recents, webSearch: web)
    }

    private func describe(_ results: [SearchResult]) -> [String] {
        results.map {
            switch $0 {
            case .calculation(_, let value): return "= \(value)"
            case .app(let match): return match.entry.name
            case .conversion(_, let result): return result
            case .generateUUID: return "generateUUID"
            case .settings: return "settings"
            case .caffeinate: return "caffeinate"
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

    @Test func builtInEntriesNeedThreeCharacters() {
        #expect(!describe(build("se")).contains("settings"))
        #expect(!describe(build("ca")).contains("caffeinate"))
        #expect(describe(build("caf")).last == "caffeinate")
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

    @Test func offersCaffeinateIgnoresSurroundingSpaces() {
        #expect(SearchResults.offersCaffeinate("  caffeine "))
        #expect(!SearchResults.offersCaffeinate("cof"))
    }
}
