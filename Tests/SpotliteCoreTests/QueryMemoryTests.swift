import Foundation
import Testing
@testable import SpotliteCore

@Suite("Query memory")
struct QueryMemoryTests {
    private let closed = Date(timeIntervalSinceReferenceDate: 1_000)

    private func memory(_ query: String) -> QueryMemory {
        var memory = QueryMemory()
        memory.remember(query, at: closed)
        return memory
    }

    @Test func recallsWithinTheRetention() {
        #expect(memory("saf").recall(retention: 10, at: closed.addingTimeInterval(10)) == "saf")
    }

    @Test func forgetsAfterTheRetention() {
        #expect(memory("saf").recall(retention: 10, at: closed.addingTimeInterval(10.5)) == nil)
    }

    @Test func zeroRetentionIsOff() {
        #expect(memory("saf").recall(retention: 0, at: closed) == nil)
    }

    @Test func anEmptyQueryIsNothingToRecall() {
        #expect(memory("").recall(retention: 30, at: closed) == nil)
        #expect(QueryMemory().recall(retention: 30) == nil)
    }

    @Test func aClockSetBackwardsRecallsNothing() {
        #expect(memory("saf").recall(retention: 30, at: closed.addingTimeInterval(-60)) == nil)
    }
}
