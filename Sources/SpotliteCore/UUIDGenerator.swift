import Foundation

public enum UUIDVersion: String, Sendable, CaseIterable {
    case v4, v7
}

/// Generation happens only when an action runs, never while searching.
public enum UUIDGenerator {
    public static func generate(_ version: UUIDVersion, now: Date = Date()) -> String {
        if version == .v4 { return UUID().uuidString.lowercased() }
        var random = SystemRandomNumberGenerator()
        return version7(now: now, random: &random).uuidString.lowercased()
    }

    /// RFC 9562: 48-bit Unix milliseconds, version 7, variant 10, 74 random bits.
    /// Time ordered across milliseconds; no promise of ordering within a millisecond.
    static func version7<R: RandomNumberGenerator>(now: Date, random: inout R) -> UUID {
        let milliseconds = now.timeIntervalSince1970 * 1_000
        let timestamp: UInt64 = milliseconds.isFinite
            ? UInt64(min(max(milliseconds, 0), Double(0xffffffffffff))) : 0
        var bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &random) }
        for index in 0..<6 { bytes[index] = UInt8(truncatingIfNeeded: timestamp >> ((5 - index) * 8)) }
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
