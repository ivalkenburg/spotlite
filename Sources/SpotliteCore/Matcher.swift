import Foundation

/// fzf-style bonus-weighted subsequence matcher.
///
/// Scratch rows are allocated once and reused across every candidate and every keystroke:
/// fresh ones per candidate would allocate on every keypress, which is exactly the cost
/// this app exists to avoid.
///
/// The buffers make this deliberately **not** thread-safe: one instance serves one
/// thread. Matching runs on the main thread only, so a single shared instance is
/// correct there; anything else needs its own.
public final class Matcher {

    /// One row of the DP tables, indexed by position in the text. For the query character
    /// being matched, the best score with that character at this position...
    private var scoreEnding: [Int]
    /// ...and the best score with it at this position or any earlier one.
    private var scoreBest: [Int]

    /// Defensive ceilings for pasted input and hostile bundle metadata. Ordinary names
    /// remain far below these values, while the scratch rows stay predictably bounded.
    public static let maxSupportedQuery = 128
    public static let maxSupportedText = 4_096

    /// Not a real score: marks a state no match can reach.
    private static let unreachable = Int.min / 4

    public init(maxText: Int = 96) {
        let text = max(1, min(maxText, Matcher.maxSupportedText))
        scoreEnding = Array(repeating: 0, count: text)
        scoreBest = Array(repeating: 0, count: text)
    }

    public func search(
        _ query: String,
        in entries: [AppEntry],
        aliases: AliasIndex = .empty,
        limit: Int = 50
    ) -> [MatchResult] {
        guard limit > 0 else { return [] }
        return search(query, in: SearchCorpus(entries: entries, aliases: aliases), limit: limit)
    }

    /// Search a prepared corpus without filtering or allocating its metadata again.
    public func search(_ query: String, in corpus: SearchCorpus, limit: Int = 50) -> [MatchResult] {
        guard limit > 0 else { return [] }
        var out = matches(query, in: corpus)
        out.sort { a, b in
            // Raw values: comparing the enums directly more than doubled search time.
            if a.tier.rawValue != b.tier.rawValue { return a.tier.rawValue > b.tier.rawValue }
            return a.score != b.score ? a.score > b.score : a.entry.tieBreaksBefore(b.entry)
        }
        return Array(out.prefix(limit))
    }

    /// Every match, in index order. For callers that rank the matches themselves, so the
    /// list is not sorted twice on every keystroke.
    func matches(_ query: String, in corpus: SearchCorpus) -> [MatchResult] {
        guard let trimmed = query.boundedTrimmedWhitespace(maximumCount: Matcher.maxSupportedQuery)
        else { return [] }
        let q = trimmed.lowercased().map(AppEntry.typeable)
        // Unicode case conversion can expand a character, so retain the post-conversion
        // check even though the source substring was already bounded without copying.
        guard !q.isEmpty, q.count <= Matcher.maxSupportedQuery else { return [] }

        let queryMask = Matcher.mask(of: q)
        var out: [MatchResult] = []

        let entries = corpus.entries
        let aliases = corpus.aliases.isEmpty ? nil : corpus.aliases
        for index in entries.indices {
            let entry = entries[index]
            let alias = aliases?[index]
            // Cheap reject: if the name lacks a letter the query needs, no match is
            // possible - unless an alias might supply it.
            if alias == nil, queryMask & ~entry.charMask != 0 { continue }

            if let alias, alias.chars.count <= Matcher.maxSupportedText, alias.chars.starts(with: q) {
                out.append(MatchResult(entry: entry,
                                       score: consecutiveScore(length: q.count, start: 0, bonus: alias.bonus),
                                       tier: .aliasPrefix))
                continue
            }

            if entry.lowerChars.count <= Matcher.maxSupportedText, entry.lowerChars.starts(with: q) {
                out.append(MatchResult(entry: entry,
                                       score: consecutiveScore(length: q.count, start: 0, bonus: entry.bonus),
                                       tier: .namePrefix))
                continue
            }

            // Find a full consecutive run before fuzzy scoring: boundary bonuses can
            // otherwise select scattered letters even when the name contains the query.
            var consecutive = bestConsecutiveScore(q, entry.lowerChars, entry.bonus)
            if let alias, let hit = bestConsecutiveScore(q, alias.chars, alias.bonus) {
                consecutive = max(consecutive ?? hit, hit)
            }
            if let consecutive {
                out.append(MatchResult(entry: entry, score: consecutive, tier: .substring))
                continue
            }

            var best = score(q, entry.lowerChars, entry.bonus)

            // A letter from the middle of an alias is an ordinary partial match; only
            // typing the alias's start makes it outrank other apps.
            if let alias, let hit = score(q, alias.chars, alias.bonus) {
                best = max(best ?? hit, hit)
            }

            // Acronym matching ("gc" -> Google Chrome) scores against the initials.
            if best == nil || q.count <= 4, let acronym = score(q, entry.initials, entry.initialBonuses) {
                best = max(best ?? acronym, acronym)
            }

            if let best { out.append(MatchResult(entry: entry, score: best)) }
        }
        return out
    }

    // MARK: - Consecutive matches

    private func consecutiveScore(length: Int, start: Int, bonus: [Int]) -> Int {
        var value = Scoring.match + bonus[start] * Scoring.firstCharMultiplier
        if start > 0 {
            value += max(Scoring.gapStart + Scoring.gapExtension * (start - 1),
                         Scoring.maxLeadingPenalty)
        }
        for offset in 1..<length {
            value += Scoring.match + bonus[start + offset] + Scoring.bonusConsecutive
        }
        return value
    }

    private func bestConsecutiveScore(_ q: [Character], _ text: [Character], _ bonus: [Int]) -> Int? {
        guard q.count <= text.count, text.count <= Matcher.maxSupportedText else { return nil }
        var best: Int?
        for start in 0...(text.count - q.count) where text[start] == q[0] {
            var offset = 1
            while offset < q.count, text[start + offset] == q[offset] { offset += 1 }
            guard offset == q.count else { continue }

            let value = consecutiveScore(length: q.count, start: start, bonus: bonus)
            best = max(best ?? value, value)
        }
        return best
    }

    // MARK: - DP

    /// The score of the best way to find `q` in `text` as scattered letters. Scores read
    /// only the row above, so a single row of each table is enough, overwritten in place.
    private func score(_ q: [Character], _ text: [Character], _ bonus: [Int]) -> Int? {
        let m = q.count, n = text.count
        guard m > 0, m <= n, n <= Matcher.maxSupportedText else { return nil }

        // The character mask cannot reject letters in the wrong order or too few
        // repetitions. Avoid filling the table when no subsequence exists.
        var matched = 0
        for character in text where character == q[matched] {
            matched += 1
            if matched == m { break }
        }
        guard matched == m else { return nil }

        if n > scoreEnding.count {
            scoreEnding = Array(repeating: 0, count: n)
            scoreBest = Array(repeating: 0, count: n)
        }

        let unreachable = Matcher.unreachable
        for i in 0..<m {
            // The row above at j - 1, kept because the cell itself is overwritten first.
            var diagonalEnding = unreachable
            var diagonalBest = unreachable
            var previousBest = unreachable

            for j in 0..<n {
                let aboveEnding = scoreEnding[j]
                let aboveBest = scoreBest[j]
                var ending = unreachable

                if q[i] == text[j] {
                    if i == 0 {
                        ending = Scoring.match + bonus[j] * Scoring.firstCharMultiplier
                        if j > 0 {
                            let leading = Scoring.gapStart + Scoring.gapExtension * (j - 1)
                            ending += max(leading, Scoring.maxLeadingPenalty)
                        }
                    } else {
                        if diagonalBest != unreachable {
                            ending = diagonalBest + Scoring.match + bonus[j]
                        }
                        // The adjacent ending can lose to an earlier match before the
                        // consecutive bonus, yet win once that bonus is included.
                        if diagonalEnding != unreachable {
                            ending = max(ending, diagonalEnding + Scoring.match + bonus[j]
                                         + Scoring.bonusConsecutive)
                        }
                    }
                }

                scoreEnding[j] = ending
                // Best-so-far: either end here, or extend a gap from the left.
                previousBest = max(ending, previousBest == unreachable ? unreachable
                                                                       : previousBest + Scoring.gapExtension)
                scoreBest[j] = previousBest
                diagonalEnding = aboveEnding
                diagonalBest = aboveBest
            }
        }

        // Take the best end column rather than the last one: reading the final column
        // would charge a gap penalty for every character *after* the match, so a match
        // near the start of a long name would be punished twice. Length preference
        // belongs in the tie-break, not the score.
        let final = scoreEnding[..<n].max() ?? unreachable
        return final == unreachable ? nil : final
    }

    static func mask(of chars: [Character]) -> UInt32 {
        var mask: UInt32 = 0
        for ch in chars {
            if let ascii = ch.asciiValue, ascii >= 97, ascii <= 122 {
                mask |= (1 << UInt32(ascii - 97))
            }
        }
        return mask
    }
}
