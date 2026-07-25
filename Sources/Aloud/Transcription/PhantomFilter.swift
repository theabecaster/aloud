import Foundation

// Phantom-word guard.
//
// The decoder occasionally invents a filler out of an utterance that never
// happened — most often "Yeah." from a short burst of room tone. Measured on
// this engine: 17 of 52 clips of real room tone between 0.36 s and 0.62 s came
// back as "Yeah." or "Mm-hmm."; nothing longer than ~0.65 s ever did. One word
// is worse than it looks downstream — the command interpreter takes it as an
// instruction and answers it, and a rewrite can grow it into a sentence.
//
// The tempting fix is an energy gate: drop anything that never rose above room
// tone. It was measured and rejected. This engine transcribes whispered speech
// accurately right down to the noise floor (a whisper at a 95th-percentile
// frame RMS of 0.010 against ambience of 0.008 still came back as a clean
// sentence), so any level threshold high enough to catch phantoms also blocks
// whispered dictation, and no energy-domain feature separated the two —
// peak-to-floor ratio and log-energy spread both overlap completely.
//
// What does separate them is the decoder's own confidence:
//
//   phantom from room tone   0.56 – 0.80   (n=17)
//   whispered sentences      0.89 – 0.99
//   deliberate "Yeah."       0.90 – 0.95   (unchanged when scaled to a whisper)
//
// Confidence is level-independent, which is the whole point: a whisper scores
// like speech because it is speech. So the guard is a two-key lock — the
// transcript must be nothing but a filler AND the decoder must be unsure of it.
enum PhantomFilter {
    // Above this the decoder is as certain as it gets about real speech; no
    // phantom in the sample set came close. Sits in the gap, nearer the
    // phantom ceiling than the speech floor because the two populations do
    // touch for single words, and a dropped filler costs less than a dropped
    // sentence.
    static let confidenceCeiling: Float = 0.85

    // Words worth discarding when they are the *entire* transcript. Everything
    // TextPolisher already strips from real dictation, plus the "yeah" family
    // the engine actually produces from silence (which the polisher keeps, and
    // is why this leaks all the way to the screen today).
    //
    // Deliberately excludes words someone might really dictate alone — "okay",
    // "sure", "thanks", "thank you", "bye", "no". Those measured 0.73–0.83 when
    // whispered, squarely inside the phantom band, so listing them would trade
    // a rare phantom for a real word going missing.
    private static let fillers: Set<String> = [
        "yeah", "yea", "ya", "yah",
        "um", "umm", "uhm", "uh", "uhh", "erm",
        "hmm", "hm", "mm", "mmm", "mhm", "mhmm", "mmhmm",
        "huh", "eh", "ah", "oh",
    ]

    // True when the whole transcript is one throwaway noise word. Punctuation
    // and the hyphen in "mm-hmm" are stripped before matching.
    static func isFillerOnly(_ text: String) -> Bool {
        let stripped = text.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .filter { $0.isLetter || $0.isWhitespace }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return false }
        return fillers.contains(stripped)
    }

    // The question the commit paths ask: is this a filler the decoder isn't
    // sure it heard? Engines that don't report a real confidence hand back 1
    // and are therefore never second-guessed here.
    static func isPhantom(text: String, confidence: Float) -> Bool {
        isFillerOnly(text) && confidence < confidenceCeiling
    }
}
