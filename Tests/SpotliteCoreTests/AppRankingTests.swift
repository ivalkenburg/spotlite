import Foundation
import Testing
@testable import SpotliteCore

@Suite("App ranking")
struct AppRankingTests {
    private func match(_ name: String, id: String, score: Int,
                       tier: MatchTier = .other, kind: EntryKind = .app) -> MatchResult {
        let entry = AppEntry(url: URL(fileURLWithPath: "/Applications/\(name).app"),
                             name: name, bundleID: id, kind: kind)
        return MatchResult(entry: entry, score: score, positions: [], tier: tier)
    }

    @Test func settingsPanesRankBelowAppsOfTheSameTier() {
        let now = Date()
        var frecency = Frecency()
        for _ in 0..<20 { frecency.recordLaunch("pane", now: now) }
        let matches = [
            match("Sharing", id: "pane", score: 200, tier: .namePrefix, kind: .settingsPane),
            match("Safari", id: "app", score: 10, tier: .namePrefix),
        ]
        let ranked = AppRanking.rank(matches, frecency: frecency, now: now)
        #expect(ranked.map(\.entry.bundleID) == ["app", "pane"])
    }

    /// "home" must not put Google cHrOMe's scattered letters above the Home pane.
    @Test func paneNameStartBeatsAScatteredAppMatch() {
        let matches = [
            match("Google Chrome", id: "app", score: 200),
            match("Home", id: "pane", score: 10, tier: .namePrefix, kind: .settingsPane),
        ]
        let ranked = AppRanking.rank(matches, frecency: Frecency())
        #expect(ranked.map(\.entry.bundleID) == ["pane", "app"])
    }

    @Test func aliasedPaneOutranksApps() {
        let matches = [
            match("Strong App", id: "app", score: 200, tier: .namePrefix),
            match("Bluetooth", id: "pane", score: 10, tier: .aliasPrefix, kind: .settingsPane),
        ]
        let ranked = AppRanking.rank(matches, frecency: Frecency())
        #expect(ranked.map(\.entry.bundleID) == ["pane", "app"])
    }

    @Test func frecencyCanPromoteAnyCandidateInTheFullMatchSet() {
        let now = Date()
        var frecency = Frecency()
        for _ in 0..<20 { frecency.recordLaunch("familiar", now: now) }
        let matches = [
            match("Slightly Better", id: "new", score: 100),
            match("Familiar", id: "familiar", score: 90),
        ]

        let ranked = AppRanking.rank(matches, frecency: frecency, now: now)
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

        let ranked = AppRanking.rank(matches, frecency: frecency, now: now)
        #expect(ranked.map(\.entry.bundleID) == ["ghostty", "github"])
    }
}
