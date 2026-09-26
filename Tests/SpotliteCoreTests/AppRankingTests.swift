import Foundation
import Testing
@testable import SpotliteCore

@Suite("App ranking")
struct AppRankingTests {
    private func match(_ name: String, id: String, score: Int,
                       tier: MatchTier = .other) -> MatchResult {
        let entry = AppEntry(url: URL(fileURLWithPath: "/Applications/\(name).app"),
                             name: name, bundleID: id)
        return MatchResult(entry: entry, score: score, positions: [], tier: tier)
    }

    @Test func hiddenCandidatesAreRemovedBeforeTheLimit() {
        let matches = (0..<60).map { index in
            match("App \(index)", id: "app.\(index)", score: 100 - index)
        }
        let hidden = Set((0..<55).map { "app.\($0)" })

        let ranked = AppRanking.rank(matches, hiddenBundleIDs: hidden,
                                     frecency: Frecency(), limit: 5)
        #expect(ranked.map(\.entry.bundleID) == (55..<60).map { "app.\($0)" })
    }

    @Test func frecencyCanPromoteAnyCandidateInTheFullMatchSet() {
        let now = Date()
        var frecency = Frecency()
        for _ in 0..<20 { frecency.recordLaunch("familiar", now: now) }
        let matches = [
            match("Slightly Better", id: "new", score: 100),
            match("Familiar", id: "familiar", score: 90),
        ]

        let ranked = AppRanking.rank(matches, hiddenBundleIDs: [],
                                     frecency: frecency, now: now)
        #expect(ranked.first?.entry.bundleID == "familiar")
    }

    @Test func frecencyNeverLiftsAnAcronymAboveANameStart() {
        let now = Date()
        var frecency = Frecency()
        for _ in 0..<50 { frecency.recordLaunch("github", now: now) }
        let matches = [
            match("GitHub Desktop", id: "github", score: 134),
            match("Ghostty", id: "ghostty", score: 104, tier: .namePrefix),
        ]

        let ranked = AppRanking.rank(matches, hiddenBundleIDs: [],
                                     frecency: frecency, now: now)
        #expect(ranked.map(\.entry.bundleID) == ["ghostty", "github"])
    }
}
