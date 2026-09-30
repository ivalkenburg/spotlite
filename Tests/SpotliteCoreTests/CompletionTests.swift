import Testing
@testable import SpotliteCore

@Suite("Completion")
struct CompletionTests {

    @Test func finishesAPrefixWithoutNamingOpen() {
        #expect(Completion.suffix(query: "saf", title: "Safari", action: "Open") == "ari")
    }

    @Test func keepsTheTitlesCaseForTheRemainder() {
        #expect(Completion.suffix(query: "a", title: "Activity Monitor", action: "Open")
                == "ctivity Monitor")
    }

    @Test func namesTheResultWhenTheQueryIsNotAPrefix() {
        #expect(Completion.suffix(query: "gc", title: "Google Chrome", action: "Open") == " – Google Chrome")
        #expect(Completion.suffix(query: "store", title: "App Store", action: "Open") == " – App Store")
    }

    /// "Wi‑Fi" is written with a non-breaking hyphen; the keyboard's "-" still starts it.
    @Test func aKeyboardHyphenCompletesAUnicodeOne() {
        #expect(Completion.suffix(query: "wi-", title: "Wi\u{2011}Fi", action: "Open") == "Fi")
    }

    @Test func aFullyTypedTitleHasNoCompletion() {
        #expect(Completion.suffix(query: "safari", title: "Safari", action: "Open") == "")
    }

    @Test func aQueryLongerThanTheTitleIsNotAPrefix() {
        #expect(Completion.suffix(query: "safarix", title: "Safari", action: "Open") == " – Safari")
    }

    @Test func prefixOnlyOmitsNonPrefixMatches() {
        #expect(Completion.suffix(query: "go", title: "Google Chrome", action: "Open", mode: .prefixOnly)
                == "ogle Chrome")
        #expect(Completion.suffix(query: "gc", title: "Google Chrome", action: "Open", mode: .prefixOnly)
                == "")
    }

    @Test func offOmitsBothForms() {
        for query in ["go", "gc"] {
            #expect(Completion.suffix(query: query, title: "Google Chrome", action: "Open", mode: .off) == "")
        }
    }

    @Test func keepsActionsOtherThanOpen() {
        #expect(Completion.suffix(query: "sl", title: "Sleep", action: "Run") == "eep – Run")
        #expect(Completion.suffix(query: "Caffeinate", title: "Caffeinate", action: "Turn On") == " – Turn On")
    }

    @Test func emptyQueryHasNoCompletion() {
        #expect(Completion.suffix(query: "", title: "Safari", action: "Open") == "")
    }
}
