import Foundation

/// The query the panel had when it closed, offered back if it reopens soon enough, so
/// closing it by accident costs nothing.
public struct QueryMemory: Sendable {
    /// The longest the Settings slider allows.
    public static let maxRetention: TimeInterval = 30

    private var query = ""
    private var closedAt: Date?

    public init() {}

    public mutating func remember(_ query: String, at now: Date = Date()) {
        self.query = query
        closedAt = now
    }

    /// The remembered query, if the panel closed at most `retention` seconds ago. A
    /// retention of zero turns the feature off.
    public func recall(retention: TimeInterval, at now: Date = Date()) -> String? {
        guard retention > 0, let closedAt, !query.isEmpty else { return nil }
        // A clock set backwards makes the interval negative; that is not "recent".
        let elapsed = now.timeIntervalSince(closedAt)
        return (0...retention).contains(elapsed) ? query : nil
    }
}
