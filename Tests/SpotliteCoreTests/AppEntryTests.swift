import Foundation
import Testing
@testable import SpotliteCore

@Suite("App entries")
struct AppEntryTests {
    private func entry(_ name: String, path: String? = nil, id: String? = "test.app",
                       kind: EntryKind = .app) -> AppEntry {
        AppEntry(url: URL(fileURLWithPath: path ?? "/Applications/\(name).app"), name: name,
                 bundleID: id, kind: kind)
    }

    /// The matcher indexes these arrays by the same offsets, without bounds checks of its own.
    @Test(arguments: ["", "Safari", "İstanbul", "ﬃ ﬂ", "Straße", "👨‍👩‍👧‍👦 Family", "e\u{301}e\u{301}",
                      "a-b_c.d/e(f", "\u{2010}\u{2011}\u{2012}", "   "])
    func derivedArraysStayParallelToTheName(name: String) {
        let app = entry(name)
        #expect(app.lowerChars.count == name.count)
        #expect(app.bonus.count == name.count)
        #expect(app.initialBonuses.count == app.initials.count)
    }

    @Test func wordAndCamelStartsEarnTheirBonuses() {
        #expect(entry("aB c").bonus == [Scoring.bonusBoundary, Scoring.bonusCamel, 0, Scoring.bonusBoundary])
    }

    @Test func charMaskHoldsOnlyLetters() {
        #expect(entry("A1-b").charMask == 0b11)
        #expect(entry("123 é").charMask == 0)
        #expect(Matcher.mask(of: ["a", "z", "1"]) == (1 | 1 << 25))
    }

    @Test func copiesShareAnIDButNotAnInstance() {
        let first = entry("Safari", path: "/Applications/Safari.app", id: "com.apple.Safari")
        let second = entry("Safari", path: "/Volumes/Old/Safari.app", id: "com.apple.Safari")
        #expect(first.id == second.id)
        #expect(first.instanceID != second.instanceID)
        #expect(first != second)
    }

    @Test func anAppWithoutABundleIDIsIdentifiedByItsPath() {
        let app = entry("Tool", path: "/Applications/Tool.app", id: nil)
        #expect(app.id == "/Applications/Tool.app")
        #expect(app.id == app.instanceID)
    }

    @Test func aCommandOrLinkIsItsOwnIDNotItsTarget() {
        let url = URL(string: "https://example.com")!
        let first = AppEntry(url: url, name: "One", bundleID: "link.1", kind: .link)
        let second = AppEntry(url: url, name: "Two", bundleID: "link.2", kind: .link)
        #expect(first.instanceID == "link.1")
        #expect(first != second)
    }

    @Test func ties() {
        let short = entry("Ab", path: "/z/Ab.app")
        let long = entry("Abc", path: "/a/Abc.app")
        let alphabetical = entry("Ac", path: "/z/Ac.app")
        let samePathLater = entry("Ab", path: "/zz/Ab.app")
        #expect(short.tieBreaksBefore(long))
        #expect(!long.tieBreaksBefore(short))
        #expect(short.tieBreaksBefore(alphabetical))
        #expect(short.tieBreaksBefore(samePathLater))
        #expect(!short.tieBreaksBefore(short))
    }

    @Test func survivesTheCache() {
        let original = entry("Safari", path: "/Applications/Safari.app", id: "com.apple.Safari",
                             kind: .settingsPane)
        let restored = AppEntry(cached: original.cached)
        #expect(restored == original)
        #expect(restored.kind == .settingsPane)
        #expect(restored.lowerChars == original.lowerChars)
    }

    @Test func sortingIgnoresCaseAndBreaksTiesByPath() {
        let sorted = AppIndex.sortedByName([
            entry("beta"), entry("Alpha"), entry("alpha", path: "/B/alpha.app"), entry("alpha", path: "/A/alpha.app"),
        ])
        #expect(sorted.map(\.instanceID) == ["/A/alpha.app", "/Applications/Alpha.app", "/B/alpha.app",
                                             "/Applications/beta.app"])
    }
}
