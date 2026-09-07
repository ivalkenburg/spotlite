import Foundation

extension String {
    /// Returns a whitespace-trimmed view only when it fits within `maximumCount`.
    /// Finding the bounds does not copy the input, and counting stops as soon as the
    /// limit is exceeded, so a large paste cannot force a second large allocation.
    func boundedTrimmedWhitespace(maximumCount: Int) -> Substring? {
        guard maximumCount > 0,
              let first = rangeOfCharacter(from: .whitespaces.inverted)?.lowerBound,
              let last = rangeOfCharacter(from: .whitespaces.inverted,
                                          options: .backwards)?.upperBound
        else { return nil }

        let trimmed = self[first..<last]
        var count = 0
        for _ in trimmed {
            count += 1
            if count > maximumCount { return nil }
        }
        return trimmed
    }
}
