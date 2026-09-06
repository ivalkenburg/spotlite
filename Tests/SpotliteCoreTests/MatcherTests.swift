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

    @Test func prefixMatchWins() {
        #expect(top("saf") == "Safari")
        #expect(top("term") == "Terminal")
        #expect(top("fire") == "Firefox")
    }

    @Test func acronymMatchesWordInitials() {
        #expect(top("gc") == "Google Chrome")
        #expect(top("qtp") == "QuickTime Player")
        #expect(top("am") == "Activity Monitor")
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

    @Test func initialsAreDerivedFromWordAndCamelBoundaries() {
        #expect(String(app("Google Chrome").initials) == "gc")
        #expect(String(app("QuickTime Player").initials) == "qtp")
        #expect(String(app("TextEdit").initials) == "te")
    }
}
