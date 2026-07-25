import Foundation

// Turns a user's correction of a dictation into candidate vocabulary
// replacements: diff the corrected text against what Aloud typed, and every
// changed word or phrase becomes a proposed Replacement ("always type X
// instead of Y"). Pure logic, no state — the History "Fix" flow drives it.
//
// The diff is a word-token LCS. Adjacent changed tokens are grouped into one
// phrase pair ("jon smith" → "Jon Smyth" is a single candidate, not two), so
// multi-word names and terms are learned whole. Deliberately conservative:
// candidates that would make a bad standing rule — punctuation tweaks,
// re-capitalized common words, whole rewritten sentences — are filtered out,
// because a wrong Replacement silently corrupts every future dictation.
enum CorrectionDiff {

    struct Candidate: Equatable {
        var from: String   // what Aloud typed
        var to: String     // what the user wants instead
    }

    // A changed phrase longer than this is a rewrite, not a vocabulary fix.
    static let maxPhraseWords = 4

    // Everyday words whose case-only changes are noise (the user re-splitting
    // a sentence re-capitalizes "the", "we", …) — never worth a standing rule.
    // Case fixes to anything else ("jon" → "Jon") are kept: they're names.
    private static let commonWords: Set<String> = [
        "a", "about", "an", "and", "are", "as", "at", "be", "been", "but",
        "by", "can", "could", "did", "do", "does", "for", "from", "had",
        "has", "have", "he", "her", "here", "him", "his", "how", "i", "if",
        "in", "into", "is", "it", "its", "just", "me", "my", "no", "not",
        "of", "on", "or", "our", "out", "over", "she", "so", "that", "the",
        "their", "them", "then", "there", "these", "they", "this", "those",
        "to", "up", "us", "was", "we", "were", "what", "when", "where",
        "who", "will", "with", "would", "yes", "you", "your"
    ]

    // The one entry point: candidate (from → to) substitutions implied by the
    // user's correction. Order follows the text; duplicates collapsed.
    static func candidates(original: String, corrected: String) -> [Candidate] {
        let a = tokens(original)
        let b = tokens(corrected)
        guard !a.isEmpty, !b.isEmpty else { return [] }
        // Pathologically long inputs would make the DP table huge; a text
        // that big is a document, not a dictation fix.
        guard a.count * b.count <= 250_000 else { return [] }

        var results: [Candidate] = []
        var fromRun: [Token] = []
        var toRun: [Token] = []

        func flush() {
            defer { fromRun = []; toRun = [] }
            let from = fromRun.map(\.word).joined(separator: " ")
            let to = toRun.map(\.word).joined(separator: " ")
            // Pure insertions/deletions aren't substitutions — no rule to learn.
            guard !from.isEmpty, !to.isEmpty, from != to else { return }
            guard fromRun.count <= maxPhraseWords else { return }
            // Case-only change made of nothing but everyday words: sentence
            // re-capitalization, not vocabulary.
            if from.lowercased() == to.lowercased(),
               fromRun.allSatisfy({ commonWords.contains($0.normalized) }) { return }
            guard !results.contains(where: {
                $0.from.caseInsensitiveCompare(from) == .orderedSame
            }) else { return }
            results.append(Candidate(from: from, to: to))
        }

        for op in align(a, b) {
            switch op {
            case .match(let o, let c):
                if o.word == c.word {
                    flush()          // identical surface — a hard anchor
                } else {
                    // Same word, different case: part of the surrounding
                    // change ("jon smith" → "Jon Smyth" stays one pair).
                    fromRun.append(o)
                    toRun.append(c)
                }
            case .delete(let o):
                fromRun.append(o)
            case .insert(let c):
                toRun.append(c)
            }
        }
        flush()
        return results
    }

    // MARK: tokens

    // A word as it appears (surrounding punctuation stripped, interior kept —
    // "don't", "Wi-Fi") plus its case-folded form used for LCS matching.
    // Matching case-insensitively means punctuation- and case-only differences
    // never split an anchor, which is exactly the noise we want to ignore.
    private struct Token {
        let word: String
        let normalized: String
    }

    private static func tokens(_ text: String) -> [Token] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            guard let first = raw.firstIndex(where: { $0.isLetter || $0.isNumber }),
                  let last = raw.lastIndex(where: { $0.isLetter || $0.isNumber })
            else { return nil }   // pure punctuation ("—") is not a word
            let word = String(raw[first...last])
            return Token(word: word, normalized: word.lowercased())
        }
    }

    // MARK: alignment

    private enum Op {
        case match(Token, Token)   // same normalized word on both sides
        case delete(Token)         // only in the original
        case insert(Token)         // only in the correction
    }

    // Classic LCS table + backtrack, on normalized words.
    private static func align(_ a: [Token], _ b: [Token]) -> [Op] {
        let n = a.count, m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i].normalized == b[j].normalized
                    ? lcs[i + 1][j + 1] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i].normalized == b[j].normalized {
                ops.append(.match(a[i], b[j])); i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                ops.append(.delete(a[i])); i += 1
            } else {
                ops.append(.insert(b[j])); j += 1
            }
        }
        while i < n { ops.append(.delete(a[i])); i += 1 }
        while j < m { ops.append(.insert(b[j])); j += 1 }
        return ops
    }
}
