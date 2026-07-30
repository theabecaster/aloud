import Foundation

// Turns a positionless typed burst into a correction — when it can be no
// other. After a mouse click the edit tracker knows *what* the user typed
// but not *where* (see EditTracker); if that burst closely resembles exactly
// one word or short phrase of the injected text and nothing else, the only
// sensible reading is that it replaced it: "Smyth" typed over a dictation
// containing "Smith" is that word's correction. This is how double-click-
// and-retype — the most common fix gesture — becomes learnable in apps whose
// text can't be read back.
//
// Held to a stricter standard than a real diff, because it is a guess:
// the match must be unique, close (edit distance scaled to length, never
// more than 3), different beyond casing, and short enough to be vocabulary.
// Zero or two plausible homes for the burst means no candidate at all —
// downstream, a wrong pair would need to repeat and be accepted by the user
// to become a rule, but the cheapest place to stop a fabrication is here.
enum CorrectionGuess {

    // Longer than this isn't a retyped word, it's new writing.
    static let maxTypedLength = 64

    static func candidate(injected: String, typed: String) -> CorrectionDiff.Candidate? {
        let typedWords = words(typed)
        guard !typedWords.isEmpty, typedWords.count <= CorrectionDiff.maxPhraseWords else { return nil }
        let to = typedWords.joined(separator: " ")
        // Tiny bursts near-match half the dictionary.
        guard to.count >= 3, to.count <= maxTypedLength else { return nil }

        let injectedWords = words(injected)
        guard !injectedWords.isEmpty, injectedWords.count <= 200 else { return nil }

        var best: (phrase: String, distance: Int)?
        var ambiguous = false
        for length in 1...min(CorrectionDiff.maxPhraseWords, injectedWords.count) {
            // A replacement doesn't change the word count by much.
            guard abs(length - typedWords.count) <= 1 else { continue }
            for start in 0...(injectedWords.count - length) {
                let phrase = injectedWords[start..<(start + length)].joined(separator: " ")
                guard phrase.lowercased() != to.lowercased() else { continue }
                let allowed = min(3, max(1, min(phrase.count, to.count) / 4))
                guard let distance = editDistance(phrase.lowercased(), to.lowercased(), limit: allowed)
                else { continue }
                if let current = best {
                    if distance < current.distance {
                        best = (phrase, distance)
                        ambiguous = false
                    } else if distance == current.distance,
                              current.phrase.lowercased() != phrase.lowercased() {
                        // Two different homes fit equally well — no guess.
                        ambiguous = true
                    }
                } else {
                    best = (phrase, distance)
                }
            }
        }
        guard let best, !ambiguous else { return nil }
        return CorrectionDiff.Candidate(from: best.phrase, to: to)
    }

    // MARK: helpers

    // Same word shape CorrectionDiff uses: whitespace-split, surrounding
    // punctuation stripped, interior kept ("don't", "Wi-Fi").
    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            guard let first = raw.firstIndex(where: { $0.isLetter || $0.isNumber }),
                  let last = raw.lastIndex(where: { $0.isLetter || $0.isNumber })
            else { return nil }
            return String(raw[first...last])
        }
    }

    // Levenshtein with a cutoff: nil the moment the distance must exceed
    // `limit`. Inputs here are a few dozen characters at most. Internal —
    // the vocabulary booster's plausibility gate leans on the same measure.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int? {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > limit { return nil }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...max(1, x.count) where !x.isEmpty {
            current[0] = i
            var rowMin = i
            for j in 1...y.count {
                current[j] = x[i - 1] == y[j - 1]
                    ? previous[j - 1]
                    : Swift.min(previous[j - 1], previous[j], current[j - 1]) + 1
                rowMin = Swift.min(rowMin, current[j])
            }
            if rowMin > limit { return nil }
            swap(&previous, &current)
        }
        let distance = previous[y.count]
        return distance <= limit ? distance : nil
    }
}
