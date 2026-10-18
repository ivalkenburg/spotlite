import Testing
@testable import SpotliteCore

@Suite("Hide undo")
struct HideUndoHistoryTests {
    @Test func consecutiveHidesUndoInReverseOrder() {
        var history = HideUndoHistory()
        history.record("safari")
        history.record("mail")
        let hidden: Set<String> = ["safari", "mail", "previously-hidden"]
        #expect(history.pop(hiddenBundleIDs: hidden) == "mail")
        #expect(history.pop(hiddenBundleIDs: hidden) == "safari")
        #expect(history.pop(hiddenBundleIDs: hidden) == nil)
    }

    @Test func skipsAppsAlreadyRestoredElsewhere() {
        var history = HideUndoHistory()
        history.record("safari")
        history.record("mail")
        #expect(history.pop(hiddenBundleIDs: ["safari"]) == "safari")
        #expect(history.pop(hiddenBundleIDs: ["mail"]) == nil)
    }

    @Test func clearDiscardsRecordedHides() {
        var history = HideUndoHistory()
        history.record("safari")
        history.clear()
        #expect(history.pop(hiddenBundleIDs: ["safari"]) == nil)
        history.record("mail")
        #expect(history.pop(hiddenBundleIDs: ["safari", "mail"]) == "mail")
    }
}
