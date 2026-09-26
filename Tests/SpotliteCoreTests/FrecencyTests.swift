import Foundation
import Testing
@testable import SpotliteCore

@Suite("Frecency")
struct FrecencyTests {

    @Test func unknownAppGetsNoBoost() {
        #expect(Frecency().multiplier(for: "never.launched") == 1.0)
    }

    @Test func launchesIncreaseTheMultiplier() {
        var f = Frecency()
        let now = Date()
        f.recordLaunch("a", now: now)
        let once = f.multiplier(for: "a", now: now)
        for _ in 0..<10 { f.recordLaunch("a", now: now) }
        #expect(f.multiplier(for: "a", now: now) > once)
    }

    @Test func boostIsCapped() {
        var f = Frecency()
        let now = Date()
        for _ in 0..<10_000 { f.recordLaunch("a", now: now) }
        #expect(f.multiplier(for: "a", now: now) <= 1.0 + Frecency.maxBoost)
    }

    @Test func boostDecaysWithAge() {
        var f = Frecency()
        let then = Date()
        for _ in 0..<20 { f.recordLaunch("a", now: then) }

        let fresh = f.multiplier(for: "a", now: then)
        let aged = f.multiplier(for: "a", now: then.addingTimeInterval(30 * 86_400))
        // One half-life should roughly halve the boost above 1.0.
        #expect(aged < fresh)
        #expect(abs((aged - 1.0) - (fresh - 1.0) / 2) < 0.01)
    }

    @Test func frecencyCannotOverturnAMateriallyBetterMatch() {
        var f = Frecency()
        let now = Date()
        for _ in 0..<10_000 { f.recordLaunch("familiar", now: now) }
        // A 100-point match with maximum frecency must still lose to a 140-point one.
        let boosted = 100.0 * f.multiplier(for: "familiar", now: now)
        #expect(boosted < 140.0)
    }

    @Test func pruneDropsUninstalledApps() {
        var f = Frecency()
        f.recordLaunch("kept")
        f.recordLaunch("gone")
        f.prune(keeping: ["kept"])
        #expect(f.records.keys.sorted() == ["kept"])
    }

    @Test func frecencyImprovesANegativeTextualScore() {
        var f = Frecency()
        let now = Date()
        for _ in 0..<20 { f.recordLaunch("familiar", now: now) }
        #expect(f.adjustedScore(-4, for: "familiar", now: now) > -4)
    }
}

@Suite("Frecency editing")
struct FrecencyEditingTests {
    @Test func forgetRemovesOnlyThatApp() {
        var f = Frecency()
        f.recordLaunch("a")
        f.recordLaunch("b")
        let forgot = f.forget("a")
        #expect(forgot)
        #expect(f.records.keys.sorted() == ["b"])
        #expect(f.multiplier(for: "a") == 1.0)
    }

    @Test func forgettingAnUnknownAppReportsNoChange() {
        var f = Frecency()
        let forgot = f.forget("never.launched")
        #expect(!forgot)
    }

    @Test func removeAllClearsEverything() {
        var f = Frecency()
        f.recordLaunch("a")
        f.recordLaunch("b")
        f.removeAll()
        #expect(f.records.isEmpty)
    }
}
