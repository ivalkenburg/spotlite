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

    /// Applies the bounded boost without reversing it when a weak textual match has a
    /// negative score. Multiplication would make such a result more negative.
    public func adjustedScore(_ textualScore: Int, for id: String, now: Date = Date()) -> Double {
        let score = Double(textualScore)
        let boost = multiplier(for: id, now: now) - 1.0
        return score + max(abs(score), Double(Scoring.match)) * boost
    }

    /// Hard ceiling on stored records, so the file cannot grow without bound even if
    /// every id stays valid.
    public static let maxRecords = 500

    /// Drops history for apps that are no longer indexed, then caps what remains.
    /// - Returns: true if anything was removed, so the caller can skip a pointless write.
    @discardableResult
    public mutating func prune(keeping ids: Set<String>, now: Date = Date()) -> Bool {
        let before = records.count
        records = records.filter { ids.contains($0.key) }

        if records.count > Frecency.maxRecords {
            // Keep the strongest by the same measure used for ranking, so pruning can
            // never drop an app that currently outranks one it keeps.
            let strongest = records
                .sorted { multiplier(for: $0.key, now: now) > multiplier(for: $1.key, now: now) }
                .prefix(Frecency.maxRecords)
            records = Dictionary(uniqueKeysWithValues: strongest.map { ($0.key, $0.value) })
        }
        return records.count != before
    }
}
