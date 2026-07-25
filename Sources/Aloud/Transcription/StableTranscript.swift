import Foundation

// Turns a stream of full re-decodes into text that only ever grows.
//
// The live engine re-decodes all audio captured so far on every tick, so each
// update is a fresh best hypothesis: later speech legitimately revises earlier
// words, and half-spoken words at the leading edge change on every pass. Typed
// straight through, that reads as the sentence rewriting itself two or three
// times a second — the words are on screen but nobody can follow them, which
// defeats the point of live typing.
//
// So a word is released to the screen only once two consecutive decodes agree
// on it (local agreement), and text already released is never taken back just
// because the newest decode is briefly less sure. Cost: one decode interval of
// extra latency, a few hundred milliseconds. What lands is text the user can
// read while still speaking, growing word by word instead of reshuffling.
//
// The unreleased tail is not lost: the commit path transcribes the whole
// recording once more and settles the field on that canonical result.
struct StableTranscript {
    // Words released to the screen so far.
    private(set) var stable: [String] = []
    // The previous decode's hypothesis, waiting for a second opinion.
    private var previous: [String] = []

    var text: String { stable.joined(separator: " ") }

    // Feed one decode. Returns the text to display when it changed, nil when
    // this decode confirmed nothing new — the common case mid-word, and the
    // signal to leave the screen completely alone.
    mutating func accept(_ hypothesis: String) -> String? {
        let words = hypothesis.split(whereSeparator: \.isWhitespace).map(String.init)
        let agreed = Array(words.prefix(Self.commonPrefixCount(previous, words)))
        previous = words
        // A shorter agreement that still matches the screen means those words
        // are merely unconfirmed again, not wrong — deleting them would be the
        // flicker this whole type exists to prevent. Only a real disagreement,
        // one that two decodes in a row make, rewrites what the user is reading.
        guard agreed.count > stable.count || Self.diverges(agreed, stable) else { return nil }
        // Words already on screen keep the spelling they were typed with: the
        // decoder re-punctuates and re-capitalizes the whole utterance as it
        // hears more ("topics first" → "topics. First" → back again), and
        // chasing that would retype the sentence for a comma. The commit pass
        // settles the field on the finished text's punctuation, once.
        let kept = zip(stable, agreed).prefix { Self.key($0) == Self.key($1) }.map(\.0)
        stable = kept + agreed.dropFirst(kept.count)
        return text
    }

    // What makes two words "the same word" for agreement purposes: the letters,
    // not the punctuation and casing the decoder is still making its mind up
    // about.
    private static func key(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static func commonPrefixCount(_ a: [String], _ b: [String]) -> Int {
        var i = 0
        while i < a.count, i < b.count, key(a[i]) == key(b[i]) { i += 1 }
        return i
    }

    private static func diverges(_ a: [String], _ b: [String]) -> Bool {
        commonPrefixCount(a, b) < min(a.count, b.count)
    }
}
