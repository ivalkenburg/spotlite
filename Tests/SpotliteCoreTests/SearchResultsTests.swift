import Foundation
import Testing
@testable import SpotliteCore

@Suite("Search results")
struct SearchResultsTests {
    private let entries = ["Safari", "Calculator", "Settings Sync", "X"].map { name in
        AppEntry(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name,
                 bundleID: "app.\(name.lowercased().replacingOccurrences(of: " ", with: "."))")
    }

    private func build(_ query: String, hidden: Set<String> = []) -> [SearchResult] {
        SearchResults.build(for: query, corpus: SearchCorpus(entries: entries, hiddenBundleIDs: hidden),
                            matcher: Matcher(), frecency: Frecency())
    }

    private func describe(_ results: [SearchResult]) -> [String] {
        results.map {
            switch $0 {
            case .calculation(_, let value): return "= \(value)"
            case .app(let match): return match.entry.name
            case .settings: return "settings"
            case .caffeinate: return "caffeinate"
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

    @Test func offersCaffeinateIgnoresSurroundingSpaces() {
        #expect(SearchResults.offersCaffeinate("  caffeine "))
        #expect(!SearchResults.offersCaffeinate("cof"))
    }
}
