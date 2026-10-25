import Foundation

public enum CaffeineDuration: Int, Sendable, CaseIterable {
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case oneHour = 3600
    case twoHours = 7200
    case untilTurnedOff = 0

    public var title: String {
        switch self {
        case .fifteenMinutes: "15 minutes"
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        case .untilTurnedOff: "Until turned off"
        }
    }
}

/// A session is deliberately not persisted. Dates measure elapsed wall time, so a
/// sleeping Mac does not pause a session and replacing one starts from the new time.
public struct CaffeineSession: Sendable, Equatable {
    public let deadline: Date?

    public init(duration: CaffeineDuration, now: Date = Date()) {
        deadline = duration == .untilTurnedOff ? nil : now.addingTimeInterval(TimeInterval(duration.rawValue))
    }

    public func hasExpired(at now: Date) -> Bool {
        deadline.map { now >= $0 } ?? false
    }
}
