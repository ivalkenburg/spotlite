import Testing
@testable import SpotliteCore

@Suite("Completion")
struct CompletionTests {

    @Test func finishesAPrefixAndNamesTheAction() {
        #expect(Completion.suffix(query: "saf", title: "Safari", action: "Open") == "ari — Open")
    }

    @Test func keepsTheTitlesCaseForTheRemainder() {
        #expect(Completion.suffix(query: "a", title: "Activity Monitor", action: "Open")
                == "ctivity Monitor — Open")
    }

    @Test func namesTheResultWhenTheQueryIsNotAPrefix() {
        #expect(Completion.suffix(query: "gc", title: "Google Chrome", action: "Open") == " — Google Chrome")
        #expect(Completion.suffix(query: "store", title: "App Store", action: "Open") == " — App Store")
    }

    /// "Wi‑Fi" is written with a non-breaking hyphen; the keyboard's "-" still starts it.
    @Test func aKeyboardHyphenCompletesAUnicodeOne() {
        #expect(Completion.suffix(query: "wi-", title: "Wi\u{2011}Fi", action: "Open") == "Fi — Open")
    }

    @Test func aFullyTypedTitleOnlyNamesTheAction() {
        #expect(Completion.suffix(query: "safari", title: "Safari", action: "Open") == " — Open")
    }

    @Test func aQueryLongerThanTheTitleIsNotAPrefix() {
        #expect(Completion.suffix(query: "safarix", title: "Safari", action: "Open") == " — Safari")
    }

    @Test func emptyQueryHasNoCompletion() {
        #expect(Completion.suffix(query: "", title: "Safari", action: "Open") == "")
    }
}
