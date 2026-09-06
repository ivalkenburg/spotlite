import Foundation

/// Launch history, blended into ranking as a bounded multiplier.
///
/// Bounded on purpose: pure fuzzy ranking means the app you launch forty times a day
/// loses forever to one you have never opened, but an unbounded frequency boost lets a
/// favourite hijack unrelated queries. The cap keeps a materially better textual match
/// ahead of a merely familiar one.
public struct Frecency: Codable, Sendable {

    public struct Record: Codable, Sendable {
        public var count: Int
        public var lastLaunch: Date
    }

    public private(set) var records: [String: Record]

    /// Maximum boost: a perfect frecency score multiplies a match by 1.35.
    public static let maxBoost = 0.35
    /// Recency half-life. A launch 30 days old carries half the weight of one today.
    public static let halfLifeDays = 30.0

    public init(records: [String: Record] = [:]) {
        self.records = records
    }

    public mutating func recordLaunch(_ id: String, now: Date = Date()) {
        var record = records[id] ?? Record(count: 0, lastLaunch: now)
        record.count += 1
        record.lastLaunch = now
        records[id] = record
    }

    /// Multiplier in [1.0, 1.35] for a candidate's textual score.
    public func multiplier(for id: String, now: Date = Date()) -> Double {
        guard let record = records[id] else { return 1.0 }

        // Diminishing returns on count: the 20th launch matters far less than the 2nd.
        let frequency = min(1.0, log2(Double(record.count) + 1) / log2(21))

        let ageDays = max(0, now.timeIntervalSince(record.lastLaunch) / 86_400)
        let recency = pow(0.5, ageDays / Frecency.halfLifeDays)

        return 1.0 + Frecency.maxBoost * frequency * recency
    }

    /// Drops history for apps that are no longer indexed, so the file cannot grow
    /// without bound as apps come and go.
    public mutating func prune(keeping ids: Set<String>) {
        records = records.filter { ids.contains($0.key) }
    }
}
