import Foundation

// Finds what a dictation turned into after the user touched it. Aloud typed
// `injected` into some field; the next session's FocusSnapshot hands back
// `fieldText` — a ≤2000-char window around the caret in which the injection
// may sit anywhere: edited, buried in other prose, clipped by the window, or
// deleted. This recovers the exact stretch of fieldText the injection became
// so CorrectionDiff can mine it for vocabulary fixes. Pure logic, no state —
// the learning pipeline drives it.
//
// The stakes are asymmetric. A missed match costs one learning opportunity;
// a wrong span manufactures a "correction" the user never made, which can
// become a standing Replacement that corrupts every future dictation. Every
// judgment call below therefore prefers nil over a guess.
enum CorrectionCapture {

    // Beyond these sizes the text is a document, not a dictation-and-fix, and
    // the sliding-window scoring below would outgrow its time budget.
    private static let maxInjectedWords = 120
    private static let maxFieldWords = 600

    // At least 60% of the injected words must survive, in order, inside the
    // best window. Below that the "match" is more coincidence than identity —
    // and a rewrite that heavy carries no vocabulary signal worth the risk.
    // Kept in integers (3/5) so threshold comparisons never touch floats.
    private static func meetsThreshold(_ lcs: Int, of count: Int) -> Bool {
        5 * lcs >= 3 * count
    }

    /// `injected`: text Aloud typed earlier. `fieldText`: focused-field text
    /// captured later. Returns the span of `fieldText` that corresponds to
    /// `injected` IF it is a confident match AND the user actually changed
    /// something; nil when unchanged, deleted, clipped, ambiguous, or too
    /// dissimilar to trust.
    static func editedSpan(injected: String, fieldText: String) -> String? {
        let a = tokens(injected)
        let b = tokens(fieldText)
        let n = a.count
        let m = b.count
        guard n >= 1, m >= 1, n <= maxInjectedWords, m <= maxFieldWords
        else { return nil }

        // A window may run 30% shorter or longer than the injection: room for
        // the user to insert or delete words inside the passage, not enough
        // to swallow the surrounding document.
        let minLength = max(1, n * 7 / 10)
        let maxLength = (n * 13 + 9) / 10
        guard m >= minLength else { return nil }

        // Interning words as integers keeps the DP inner loop cheap.
        var ids: [String: Int] = [:]
        func id(_ word: String) -> Int {
            if let existing = ids[word] { return existing }
            ids[word] = ids.count
            return ids.count - 1
        }
        let aIds = a.map { id($0.normalized) }
        let bIds = b.map { id($0.normalized) }
        let aSet = Set(aIds)

        // Prefix counts of field words that appear in the injection at all —
        // an upper bound on any window's LCS, so hopeless starts skip the DP.
        var reachable = [Int](repeating: 0, count: m + 1)
        for k in 0..<m {
            reachable[k + 1] = reachable[k] + (aSet.contains(bIds[k]) ? 1 : 0)
        }

        struct Window { var lcs: Int; var start: Int; var length: Int }
        var windows: [Window] = []

        var previous = [Int](repeating: 0, count: maxLength + 1)
        var current = previous

        for start in 0...(m - minLength) {
            let windowLength = min(maxLength, m - start)
            guard meetsThreshold(reachable[start + windowLength] - reachable[start],
                                 of: n) else { continue }

            // One DP per start scores every window length at once: after the
            // last row, previous[L] is the LCS of the whole injection against
            // the window's first L words.
            for j in 0...windowLength { previous[j] = 0 }
            for i in 0..<n {
                current[0] = 0
                let ai = aIds[i]
                for j in 0..<windowLength {
                    current[j + 1] = ai == bIds[start + j]
                        ? previous[j] + 1
                        : max(previous[j + 1], current[j])
                }
                swap(&previous, &current)
            }
            let lcs = previous[windowLength]
            guard meetsThreshold(lcs, of: n) else { continue }

            // The shortest window that keeps the full LCS: both edges land on
            // matched words. A boundary word the user replaced falls outside
            // it, forfeiting that fix — but an unmatched edge word could just
            // as well be neighboring document text, and dragging a neighbor
            // into the span invents a substitution that never happened. The
            // safe reading wins.
            var length = minLength
            while previous[length] < lcs { length += 1 }
            windows.append(Window(lcs: lcs, start: start, length: length))
        }

        guard let bestLCS = windows.map(\.lcs).max() else { return nil }
        let tied = windows.filter { $0.lcs == bestLCS }
        // Tightest window first: when the injection sits unchanged next to
        // text the user typed afterwards, the exact match must win over a
        // looser window that differs only by swallowed neighbors.
        guard let best = tied.min(by: {
            ($0.length, $0.start) < ($1.length, $1.start)
        }) else { return nil }
        // Two separate places score equally well — repeated phrasing, or the
        // same thing dictated twice. Guessing which one was ours risks
        // learning from an edit the user never made.
        guard !tied.contains(where: {
            $0.start + $0.length <= best.start || best.start + best.length <= $0.start
        }) else { return nil }

        let lower = b[best.start].range.lowerBound
        let upper = b[best.start + best.length - 1].range.upperBound
        let span = String(fieldText[lower..<upper])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Unchanged means nothing to learn. Whitespace differences are
        // invisible to the token match and carry no vocabulary signal, so
        // they don't count as change; case and punctuation edits are real
        // and pass through for CorrectionDiff to judge.
        guard collapsed(span) != collapsed(injected) else { return nil }
        return span
    }

    // MARK: tokens

    // A word's case-folded form (surrounding punctuation stripped, interior
    // kept — the same reading CorrectionDiff uses) plus where its raw chunk
    // sits in the source, so a matched window can be handed back verbatim:
    // original casing, punctuation, and paragraph breaks intact.
    private struct Token {
        let normalized: String
        let range: Range<String.Index>
    }

    private static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace {
                end = text.index(after: end)
            }
            let raw = text[index..<end]
            if let first = raw.firstIndex(where: { $0.isLetter || $0.isNumber }),
               let last = raw.lastIndex(where: { $0.isLetter || $0.isNumber }) {
                // Pure punctuation ("—") is not a word.
                result.append(Token(normalized: raw[first...last].lowercased(),
                                    range: index..<end))
            }
            index = end
        }
        return result
    }

    // Whitespace-insensitive equality: the injector and the field need not
    // agree on how many spaces or which newline sits between words.
    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
