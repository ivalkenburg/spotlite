import Foundation
import Testing
@testable import SpotliteCore

private func app(_ name: String) -> AppEntry {
    AppEntry(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name, bundleID: "test.\(name)")
}

private let corpus = [
    "Safari", "Google Chrome", "Firefox", "App Store", "Automator", "Activity Monitor",
    "Calculator", "Calendar", "Terminal", "TextEdit", "System Settings", "Font Book",
    "Image Capture", "Digital Color Meter", "QuickTime Player", "Photo Booth",
].map(app)

/// A fresh matcher per call: Matcher reuses scratch buffers and is single-threaded
/// by design, and swift-testing runs these in parallel.
private func search(_ query: String) -> [MatchResult] {
    Matcher().search(query, in: corpus)
}

private func top(_ query: String) -> String? {
    search(query).first?.entry.name
}

@Suite("Fuzzy scoring")
struct FuzzyScoringTests {

    @Test func preparedCorpusPreservesSearchResultsAndLimits() {
        let matcher = Matcher()
        let aliases = AliasIndex(aliases: ["test.Firefox": "browser"])
        let prepared = SearchCorpus(entries: corpus, aliases: aliases)
        for query in ["saf", "gc", "browser", "zz", "", String(repeating: "s", count: 1_000)] {
            for limit in [-1, 0, 1, 3, 50] {
                let entriesResult = matcher.search(query, in: corpus, aliases: aliases, limit: limit)
                let preparedResult = matcher.search(query, in: prepared, limit: limit)
                #expect(preparedResult.map(\.entry.instanceID) == entriesResult.map(\.entry.instanceID))
                #expect(preparedResult.map(\.score) == entriesResult.map(\.score))
                #expect(preparedResult.map(\.positions) == entriesResult.map(\.positions))
                #expect(preparedResult.map(\.tier) == entriesResult.map(\.tier))
            }
        }
    }

    @Test func prefixMatchWins() {
        #expect(top("saf") == "Safari")
        #expect(top("term") == "Terminal")
        #expect(top("fire") == "Firefox")
    }

    @Test func acronymMatchesWordInitials() {
        // System Settings writes "Wi‑Fi" with a non-breaking hyphen.
        #expect(Matcher().search("wf", in: [app("Wi\u{2011}Fi")]).first?.positions == [0, 3])
        // Typed with a keyboard hyphen, it is still the start of the name.
        #expect(Matcher().search("wi-fi", in: [app("Wi\u{2011}Fi")]).first?.tier == .namePrefix)
        #expect(top("gc") == "Google Chrome")
        #expect(top("qtp") == "QuickTime Player")
        #expect(top("am") == "Activity Monitor")
    }

    @Test func nameStartBeatsAnAcronym() {
        // "gh" is GitHub Desktop's acronym (the H is a camel hump) but Ghostty's start.
        let ranked = Matcher().search("gh", in: [app("GitHub Desktop"), app("Ghostty")])
        #expect(ranked.map(\.entry.name) == ["Ghostty", "GitHub Desktop"])
        #expect(ranked.first?.positions == [0, 1])
        #expect(Matcher().search("tv", in: [app("Ticket Viewer"), app("TV")]).first?.entry.name == "TV")
        #expect(Matcher().search("map", in: [app("Markdown Preview"), app("Maps")]).first?.entry.name == "Maps")
    }

    @Test func wordStartBeatsMidWord() {
        // "mo" starts a word in "Activity Monitor" but sits mid-word in "Automator".
        let names = search("mo").map(\.entry.name)
        let wordStart = names.firstIndex(of: "Activity Monitor")
        let midWord = names.firstIndex(of: "Automator")
        #expect(wordStart != nil && midWord != nil)
        #expect(wordStart! < midWord!)
    }

    @Test func consecutiveRunBeatsScatteredSubsequence() {
        let results = search("cal")
        #expect(results.first?.entry.name == "Calculator" || results.first?.entry.name == "Calendar")
        // "Activity Monitor" only matches c-a-l scattered, so it must rank below both.
        let names = results.map(\.entry.name)
        if let scattered = names.firstIndex(of: "Activity Monitor") {
            #expect(scattered > names.firstIndex(of: "Calculator")!)
        }
    }

    @Test func adjacentPathCanWinAfterItsBonus() {
        // The first A wins before the bonus, but the final AB wins with it.
        let result = Matcher().search("ab", in: [app("A-AB")]).first
        #expect(result?.score == 100)
        #expect(result?.positions == [2, 3])
    }

    @Test func nonMatchesAreExcluded() {
        #expect(search("zzzz").isEmpty)
        #expect(search("").isEmpty)
        // Every letter must be present: "safarix" has no x.
        #expect(search("safarix").isEmpty)
    }

    @Test func matchedPositionsPointAtTheMatchedCharacters() {
        let result = search("saf").first!
        let chars = Array(result.entry.name)
        #expect(result.positions.count == 3)
        #expect(String(result.positions.map { chars[$0] }).lowercased() == "saf")
    }

    @Test func acronymPositionsMapBackToWordStarts() {
        let result = search("gc").first!
        #expect(result.entry.name == "Google Chrome")
        #expect(result.positions == [0, 7])
    }

    @Test func nameStartBeatsWordStartDeeperInTheName() {
        // "a" opens "Acorn" but only opens the second word of "Keychain Access".
        let pair = [app("Acorn"), app("Keychain Access")]
        let ranked = Matcher().search("a", in: pair).map(\.entry.name)
        #expect(ranked == ["Acorn", "Keychain Access"])
    }

    @Test func trailingCharactersDoNotReduceTheScore() {
        // A match at position 0 must score the same regardless of how much name follows,
        // otherwise a long name is penalised twice — once in score, once in the tie-break.
        let results = search("c")
        let calculator = results.first { $0.entry.name == "Calculator" }!
        let calendar = results.first { $0.entry.name == "Calendar" }!
        #expect(calculator.score == calendar.score)
    }

    @Test func rankingIsDeterministicAcrossRuns() {
        let first = search("a").map(\.entry.name)
        let second = search("a").map(\.entry.name)
        #expect(first == second)
    }

    @Test func aliasBeatsAnIncidentalNameMatch() {
        let apps = [app("Passwords"), app("Photoshop")]
        let aliases = AliasIndex(aliases: ["test.Photoshop": "ps"])

        // Without the alias "ps" reaches Passwords; with it, Photoshop must win.
        #expect(Matcher().search("ps", in: apps).first?.entry.name == "Passwords")
        #expect(Matcher().search("ps", in: apps, aliases: aliases).first?.entry.name == "Photoshop")
    }

    @Test func aliasMatchesEvenWhenTheNameLacksTheLetters() {
        let apps = [app("Affinity Photo")]
        let aliases = AliasIndex(aliases: ["test.Affinity Photo": "xy"])
        // "xy" shares no letters with the name, so only the alias can match it.
        #expect(Matcher().search("xy", in: apps).isEmpty)
        #expect(Matcher().search("xy", in: apps, aliases: aliases).count == 1)
    }

    @Test func aliasMatchHighlightsNothing() {
        let apps = [app("Photoshop")]
        let aliases = AliasIndex(aliases: ["test.Photoshop": "ps"])
        // The matched characters live in the alias, not in the displayed name.
        #expect(Matcher().search("ps", in: apps, aliases: aliases).first?.positions.isEmpty == true)
    }

    @Test func aliasOnlyOutranksNamesWhenItsStartIsTyped() {
        let apps = [app("Safari"), app("Photoshop")]
        let aliases = AliasIndex(aliases: ["test.Photoshop": "ps"])
        #expect(Matcher().search("p", in: apps, aliases: aliases).first?.entry.name == "Photoshop")
        // "s" sits inside the alias, so it must not take over a search for Safari.
        #expect(Matcher().search("s", in: apps, aliases: aliases).first?.entry.name == "Safari")
    }

    @Test func blankAliasesAreIgnored() {
        #expect(AliasIndex(aliases: ["a": "  ", "b": ""]).isEmpty)
    }

    @Test func initialsAreDerivedFromWordAndCamelBoundaries() {
        #expect(String(app("Google Chrome").initials) == "gc")
        #expect(String(app("QuickTime Player").initials) == "qtp")
        #expect(String(app("TextEdit").initials) == "te")
    }

    @Test func namesBeyondTheOriginalScratchCapacityStillMatch() {
        let longName = "Searchable" + String(repeating: " Application", count: 10)
        let result = Matcher().search("search", in: [app(longName)])
        #expect(result.first?.entry.name == longName)
    }

    @Test func invalidLimitsAndOversizedQueriesAreRejectedSafely() {
        #expect(Matcher().search("s", in: corpus, limit: 0).isEmpty)
        let oversized = String(repeating: "s", count: 100_000)
        #expect(Matcher().search(oversized, in: corpus).isEmpty)
    }

    @Test func queryLimitIsAppliedAfterTrimmingWithoutChangingAcceptedInput() {
        let padding = String(repeating: " ", count: 10_000)
        #expect(Matcher().search(padding + "saf" + padding, in: corpus).first?.entry.name == "Safari")
    }
}
