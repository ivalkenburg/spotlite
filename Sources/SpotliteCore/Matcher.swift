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
        guard limit > 0,
              let trimmed = query.boundedTrimmedWhitespace(maximumCount: Matcher.maxSupportedQuery)
        else { return [] }
        let q = Array(trimmed.lowercased())
        // Unicode case conversion can expand a character, so retain the post-conversion
        // check even though the source substring was already bounded without copying.
        guard !q.isEmpty, q.count <= Matcher.maxSupportedQuery else { return [] }

        ensureCapacity(query: q.count, text: max(capacity.text, aliases.maxLength))

        let queryMask = Matcher.mask(of: q)
        var out: [MatchResult] = []
        out.reserveCapacity(min(entries.count, limit * 2))

        for entry in entries {
            let alias = aliases.isEmpty ? nil : aliases[entry.id]
            // The common path is one integer comparison. A longer name grows the shared
            // buffer once, when first encountered, and subsequent searches reuse it.
            let neededText = max(entry.lowerChars.count, entry.initials.count,
                                 alias?.chars.count ?? 0)
            if neededText > capacity.text {
                ensureCapacity(query: q.count, text: neededText)
            }

            // Cheap reject: if the name lacks a letter the query needs, no match is
            // possible - unless an alias might supply it.
            if alias == nil, queryMask & ~entry.charMask != 0 { continue }

            // An alias match highlights nothing: the matched characters are in the alias,
            // not in the displayed name, so there is nothing honest to embolden.
            if let alias, alias.chars.starts(with: q), let hit = score(q, alias.chars, alias.bonus) {
                out.append(MatchResult(entry: entry, score: hit.score, positions: [], tier: .aliasPrefix))
                continue
            }

            // Highlights exactly the typed letters, which the completion then finishes.
            if entry.lowerChars.starts(with: q), let hit = score(q, entry.lowerChars, entry.bonus) {
                out.append(MatchResult(entry: entry, score: hit.score, positions: Array(0..<q.count),
                                       tier: .namePrefix))
                continue
            }

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

        out.sort { a, b in
            // Raw values: comparing the enums directly more than doubled search time.
            if a.tier.rawValue != b.tier.rawValue { return a.tier.rawValue > b.tier.rawValue }
            return a.score != b.score ? a.score > b.score : a.entry.tieBreaksBefore(b.entry)
        }
        return Array(out.prefix(limit))
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
        // Names longer than the scratch buffer simply don't match; growing the buffer
        // mid-search would defeat the point of preallocating it.
        guard m <= capacity.query, n <= capacity.text else { return nil }

        let stride = capacity.text

        for i in 0..<m {
            var previousBest = Int.min / 4
            let row = i * stride
            let previousRow = (i - 1) * stride

            for j in 0..<n {
                var ending = Int.min / 4

                if q[i] == text[j] {
                    let carried: Int
                    if i == 0 {
                        carried = 0
                    } else if j == 0 {
                        carried = Int.min / 4
                    } else {
                        carried = scoreBest[previousRow + j - 1]
                    }

                    if carried > Int.min / 8 {
                        var value = carried + Scoring.match + bonus[j]
                        if i == 0 {
                            value += bonus[j] * (Scoring.firstCharMultiplier - 1)
                            if j > 0 {
                                let leading = Scoring.gapStart + Scoring.gapExtension * (j - 1)
                                value += max(leading, Scoring.maxLeadingPenalty)
                            }
                        }
                        // Consecutive run: the previous query char matched at j-1.
                        if i > 0, j > 0, scoreEnding[previousRow + j - 1] > Int.min / 8,
                           scoreEnding[previousRow + j - 1] == scoreBest[previousRow + j - 1] {
                            value += Scoring.bonusConsecutive
                        }
                        ending = value
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

        return (final, backtrack(m: m, from: endColumn, stride: stride))
    }

    /// Walks the DP tables backwards to recover which characters were matched.
    private func backtrack(m: Int, from endColumn: Int, stride: Int) -> [Int] {
        var positions = [Int]()
        positions.reserveCapacity(m)
        var j = endColumn
        var i = m - 1

        while i >= 0 && j >= 0 {
            if scoreEnding[i * stride + j] == scoreBest[i * stride + j],
               scoreEnding[i * stride + j] > Int.min / 8 {
                positions.append(j)
                i -= 1
                j -= 1
            } else {
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
