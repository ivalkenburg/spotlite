import Foundation

/// fzf-style bonus-weighted subsequence matcher.
///
/// Scratch buffers are allocated once and reused across every candidate and every
/// keystroke — a fresh DP matrix per candidate would allocate megabytes per keypress,
/// which is exactly the cost this app exists to avoid.
///
/// The buffers make this deliberately **not** thread-safe: one instance serves one
/// thread. Matching runs on the main thread only, so a single shared instance is
/// correct there; anything else needs its own.
public final class Matcher {

    /// Best score for query[0...i] where query[i] is matched at text[j].
    private var scoreEnding: [Int]
    /// Best score for query[0...i] considering text[0...j], match ending anywhere.
    private var scoreBest: [Int]
    private var capacity: (query: Int, text: Int)

    /// Defensive ceilings for pasted input and hostile bundle metadata. Ordinary names
    /// remain far below these values, while the DP matrix stays predictably bounded.
    public static let maxSupportedQuery = 128
    public static let maxSupportedText = 4_096

    public init(maxQuery: Int = 48, maxText: Int = 96) {
        let query = max(1, min(maxQuery, Matcher.maxSupportedQuery))
        let text = max(1, min(maxText, Matcher.maxSupportedText))
        capacity = (query, text)
        scoreEnding = Array(repeating: 0, count: query * text)
        scoreBest = Array(repeating: 0, count: query * text)
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
        let aliases = corpus.hasAliases ? corpus.aliases : nil
        for index in entries.indices {
            let entry = entries[index]
            let alias = aliases?[index]
            // Cheap reject: if the name lacks a letter the query needs, no match is
            // possible - unless an alias might supply it.
            if alias == nil, queryMask & ~entry.charMask != 0 { continue }

            // An alias match highlights nothing: the matched characters are in the alias,
            // not in the displayed name, so there is nothing honest to embolden.
            if let alias, alias.chars.count <= Matcher.maxSupportedText, alias.chars.starts(with: q) {
                out.append(MatchResult(entry: entry,
                                       score: consecutiveScore(length: q.count, start: 0, bonus: alias.bonus),
                                       positions: [], tier: .aliasPrefix))
                continue
            }

            // Highlights exactly the typed letters, which the completion then finishes.
            if entry.lowerChars.count <= Matcher.maxSupportedText, entry.lowerChars.starts(with: q) {
                out.append(MatchResult(entry: entry,
                                       score: consecutiveScore(length: q.count, start: 0, bonus: entry.bonus),
                                       positions: Array(0..<q.count),
                                       tier: .namePrefix))
                continue
            }

            // Find a full consecutive run before fuzzy scoring: boundary bonuses can
            // otherwise select scattered letters even when the name contains the query.
            var consecutive = consecutiveMatch(q, entry.lowerChars, entry.bonus)
            if let alias, let hit = consecutiveMatch(q, alias.chars, alias.bonus),
               consecutive == nil || hit.score > consecutive!.score {
                consecutive = (score: hit.score, start: nil)
            }
            if let consecutive {
                out.append(MatchResult(entry: entry, score: consecutive.score,
                                       positions: consecutive.start.map { Array($0..<($0 + q.count)) } ?? [],
                                       tier: .substring))
                continue
            }

            // Only fuzzy matches need the DP buffers. Unsupported metadata must not
            // expand them to the ceiling when it will be rejected by the scorer.
            let nameLength = entry.lowerChars.count
            let initialsLength = entry.initials.count
            let aliasLength = alias?.chars.count ?? 0
            let neededText = max(nameLength <= Matcher.maxSupportedText ? nameLength : 0,
                                 initialsLength <= Matcher.maxSupportedText ? initialsLength : 0,
                                 aliasLength <= Matcher.maxSupportedText ? aliasLength : 0)
            ensureCapacity(query: q.count, text: neededText)
            var best = score(q, entry.lowerChars, entry.bonus)

            // A letter from the middle of an alias is an ordinary partial match; only
            // typing the alias's start makes it outrank other apps.
            if let alias, let hit = score(q, alias.chars, alias.bonus),
               best == nil || hit.score > best!.score {
                best = (score: hit.score, positions: [])
            }

            // Acronym matching ("gc" -> Google Chrome) scores against the initials, then
            // maps positions back onto the full name.
            if best == nil || q.count <= 4,
               let acronym = score(q, entry.initials, entry.initialBonuses) {
                let mapped = acronym.positions.map { entry.initialIndices[$0] }
                let candidate = (score: acronym.score, positions: mapped)
                if best == nil || candidate.score > best!.score { best = candidate }
            }

            if let best {
                out.append(MatchResult(entry: entry, score: best.score, positions: best.positions))
            }
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

    private func consecutiveMatch(_ q: [Character], _ text: [Character], _ bonus: [Int])
        -> (score: Int, start: Int?)? {
        guard q.count <= text.count, text.count <= Matcher.maxSupportedText else { return nil }
        var bestScore = Int.min
        var bestStart = 0
        for start in 0...(text.count - q.count) where text[start] == q[0] {
            var offset = 1
            while offset < q.count, text[start + offset] == q[offset] { offset += 1 }
            guard offset == q.count else { continue }

            let value = consecutiveScore(length: q.count, start: start, bonus: bonus)
            if value > bestScore {
                bestScore = value
                bestStart = start
            }
        }
        guard bestScore != Int.min else { return nil }
        return (bestScore, bestStart)
    }

    // MARK: - DP

    private func ensureCapacity(query: Int, text: Int) {
        let neededQuery = min(max(query, capacity.query), Matcher.maxSupportedQuery)
        let neededText = min(max(text, capacity.text), Matcher.maxSupportedText)
        guard neededQuery != capacity.query || neededText != capacity.text else { return }
        capacity = (neededQuery, neededText)
        scoreEnding = Array(repeating: 0, count: neededQuery * neededText)
        scoreBest = Array(repeating: 0, count: neededQuery * neededText)
    }

    private func score(_ q: [Character], _ text: [Character], _ bonus: [Int]) -> (score: Int, positions: [Int])? {
        let m = q.count, n = text.count
        guard m > 0, n > 0, m <= n else { return nil }
        // The caller grows the buffers once per fuzzy candidate, within the ceilings.
        guard m <= capacity.query, n <= capacity.text else { return nil }

        // The character mask cannot reject letters in the wrong order or too few
        // repetitions. Avoid filling the DP matrix when no subsequence exists.
        var matched = 0
        for character in text where character == q[matched] {
            matched += 1
            if matched == m { break }
        }
        guard matched == m else { return nil }

        let stride = capacity.text

        for i in 0..<m {
            var previousBest = Int.min / 4
            let row = i * stride
            let previousRow = (i - 1) * stride

            for j in 0..<n {
                var ending = Int.min / 4

                if q[i] == text[j] {
                    if i == 0 {
                        var value = Scoring.match + bonus[j] * Scoring.firstCharMultiplier
                        if j > 0 {
                            let leading = Scoring.gapStart + Scoring.gapExtension * (j - 1)
                            value += max(leading, Scoring.maxLeadingPenalty)
                        }
                        ending = value
                    } else if j > 0 {
                        let previous = previousRow + j - 1
                        let gapped = scoreBest[previous]
                        if gapped > Int.min / 8 {
                            ending = gapped + Scoring.match + bonus[j]
                        }
                        // The adjacent ending can lose to an earlier match before the
                        // consecutive bonus, yet win once that bonus is included.
                        let adjacent = scoreEnding[previous]
                        if adjacent > Int.min / 8 {
                            ending = max(ending, adjacent + Scoring.match + bonus[j]
                                         + Scoring.bonusConsecutive)
                        }
                    }
                }

                scoreEnding[row + j] = ending

                // Best-so-far: either end here, or extend a gap from the left.
                let gapped = previousBest + (previousBest == Int.min / 4 ? 0 : Scoring.gapExtension)
                previousBest = max(ending, gapped)
                scoreBest[row + j] = previousBest
            }
        }

        // Take the best end column rather than the last one: reading the final column
        // would charge a gap penalty for every character *after* the match, so a match
        // near the start of a long name would be punished twice. Length preference
        // belongs in the tie-break, not the score.
        var final = Int.min / 4
        var endColumn = n - 1
        let lastRow = (m - 1) * stride
        for j in 0..<n where scoreEnding[lastRow + j] > final {
            final = scoreEnding[lastRow + j]
            endColumn = j
        }
        guard final > Int.min / 8 else { return nil }

        return (final, backtrack(m: m, from: endColumn, stride: stride, bonus: bonus))
    }

    /// Walks the DP tables backwards to recover which characters were matched.
    private func backtrack(m: Int, from endColumn: Int, stride: Int, bonus: [Int]) -> [Int] {
        var positions = [Int]()
        positions.reserveCapacity(m)
        var j = endColumn
        var i = m - 1

        while i >= 0 && j >= 0 {
            positions.append(j)
            guard i > 0 else { break }
            let previous = (i - 1) * stride + j - 1
            if j > 0, scoreEnding[previous] > Int.min / 8,
               scoreEnding[i * stride + j] == scoreEnding[previous] + Scoring.match
                    + bonus[j] + Scoring.bonusConsecutive {
                // This row chose the adjacent predecessor, which need not be the
                // previous row's best-so-far state.
                i -= 1
                j -= 1
                continue
            }
            // The row chose a gapped predecessor. Walk back to the match that
            // produced the previous row's best score at j-1.
            i -= 1
            j -= 1
            while j >= 0, (scoreEnding[i * stride + j] <= Int.min / 8
                           || scoreEnding[i * stride + j] != scoreBest[i * stride + j]) {
                j -= 1
            }
        }
        return positions.reversed()
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
