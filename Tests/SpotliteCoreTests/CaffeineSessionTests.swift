import Foundation
import Testing
@testable import SpotliteCore

@Suite("Caffeinate sessions")
struct CaffeineSessionTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test(arguments: [CaffeineDuration.fifteenMinutes, .thirtyMinutes, .oneHour, .twoHours])
    func timedSessionsExpireAtTheirDeadlineIncludingSleep(_ duration: CaffeineDuration) throws {
        let session = CaffeineSession(duration: duration, now: start)
        let deadline = try #require(session.deadline)
        #expect(deadline.timeIntervalSince(start) == Double(duration.rawValue))
        #expect(!session.hasExpired(at: deadline.addingTimeInterval(-0.001)))
        #expect(session.hasExpired(at: deadline))
        // Checking after a long sleep expires it immediately, without counting ticks.
        #expect(session.hasExpired(at: deadline.addingTimeInterval(86_400)))
    }

    @Test func replacingADurationStartsFromNowRatherThanExtendingIt() {
        var session = CaffeineSession(duration: .oneHour, now: start)
        let later = start.addingTimeInterval(600)
        session = CaffeineSession(duration: .thirtyMinutes, now: later)
        #expect(session.deadline == later.addingTimeInterval(1800))
        session = CaffeineSession(duration: .thirtyMinutes, now: later.addingTimeInterval(60))
        #expect(session.deadline == later.addingTimeInterval(1860))
        session = CaffeineSession(duration: .untilTurnedOff, now: later)
        #expect(session.deadline == nil)
        #expect(!session.hasExpired(at: .distantFuture))
    }
}
