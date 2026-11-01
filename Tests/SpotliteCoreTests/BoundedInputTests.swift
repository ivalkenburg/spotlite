import Testing
@testable import SpotliteCore

@Suite("Bounded input")
struct BoundedInputTests {
    @Test func trimsEveryKindOfWhitespace() {
        #expect(" \t safari \t ".boundedTrimmedWhitespace(maximumCount: 10) == "safari")
        #expect("\nsafari\r\n".boundedTrimmedWhitespace(maximumCount: 10) == "safari")
        #expect("two words".boundedTrimmedWhitespace(maximumCount: 10) == "two words")
    }

    @Test func blankInputHasNoText() {
        #expect("".boundedTrimmedWhitespace(maximumCount: 10) == nil)
        #expect(" \t\n ".boundedTrimmedWhitespace(maximumCount: 10) == nil)
    }

    @Test func theLimitCountsCharactersAfterTrimming() {
        #expect("   abc   ".boundedTrimmedWhitespace(maximumCount: 3) == "abc")
        #expect("abcd".boundedTrimmedWhitespace(maximumCount: 3) == nil)
        #expect("👨‍👩‍👧‍👦👨‍👩‍👧‍👦".boundedTrimmedWhitespace(maximumCount: 2) != nil)
        #expect("abc".boundedTrimmedWhitespace(maximumCount: 0) == nil)
    }
}
