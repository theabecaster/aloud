import Foundation

// Bounds what a live preview tick has to decode.
//
// Re-decoding the whole session every tick reads beautifully — each update is
// a full-context hypothesis — but its cost grows with the session: past the
// model's window the engine starts chunking internally, and a few minutes of
// hands-free dictation has every 0.2 s tick paying for the entire recording.
// The preview falls behind the voice exactly when the session is longest.
//
// So the session is decoded as a chain of chunks. One live window (at most the
// model's own window) is re-decoded per tick; when it fills up, its hypothesis
// is frozen as finished text, and the window restarts where that decode ended.
// Frozen text is never decoded again — per-tick cost stays one model window no
// matter how long the session runs.
//
// The seam is the quality risk: cut mid-word and both the frozen tail and the
// next window's opening decode garbage. Two guards: the roll waits for the
// window's trailing edge to go quiet (a natural pause) before cutting, and a
// hard cap short of the model window forces the cut only when someone truly
// speaks that long without a breath. Frozen text also gives up the late
// full-context revisions the old scheme allowed — accepted, because the commit
// still batch-transcribes the entire recording and settles the field on that.
struct ChunkedLivePreview {
    // Window length at which a quiet trailing edge is allowed to end the
    // chunk: late enough that most of the window is real context, early
    // enough that a pause is usually found before the hard cap.
    static let rollTargetSamples = 176_000        // 11 s
    // Never let the window reach the model's 15 s limit — past it the engine
    // chunks internally and the per-tick cost starts growing again.
    static let hardCapSamples = 232_000           // 14.5 s
    // How much trailing audio must be quiet to count as a pause.
    static let tailSamples = 4_000                // 0.25 s

    // Absolute sample offset where the live window begins. The pump decodes
    // buffer[windowStart...] each tick.
    private(set) var windowStart = 0
    // Finished chunks' hypotheses, in order.
    private var frozenChunks: [String] = []
    // Agreement filter for the live window only; reset at every roll.
    private var stable = StableTranscript()
    // What the screen last saw, so a decode (or a roll) that lands on the
    // same text is a nil — the signal to leave the screen alone.
    private var lastDisplay = ""

    // Feed one decode of the live window, which covered the buffer up to
    // absolute offset `decodedEnd`. Returns the cumulative session text to
    // display, or nil when this decode changed nothing on screen.
    mutating func accept(_ hypothesis: String, decodedEnd: Int, tailQuiet: Bool) -> String? {
        var display: String?
        // A window that is nothing but a filler is withheld entirely: with
        // most of the window silent (a pause after the last roll), the decoder
        // hallucinates "Yeah." from room tone exactly like it does from a
        // too-short dictation. Real speech either continues — the filler stops
        // being the whole window — or the commit re-decodes with full context
        // and rules on it.
        let withheld = hypothesis.isEmpty || PhantomFilter.isFillerOnly(hypothesis)
        if !withheld, let confirmed = stable.accept(hypothesis) {
            display = compose(with: confirmed)
        }
        let windowLength = decodedEnd - windowStart
        if windowLength >= Self.hardCapSamples
            || (windowLength >= Self.rollTargetSamples && tailQuiet) {
            if !withheld { frozenChunks.append(hypothesis) }
            windowStart = decodedEnd
            stable = StableTranscript()
            // The roll promotes the window's whole hypothesis, including words
            // the agreement filter was still holding back — the screen catches
            // up in one step at what is usually a natural pause.
            display = compose(with: "")
        }
        guard let text = display, !text.isEmpty, text != lastDisplay else { return nil }
        lastDisplay = text
        return text
    }

    // True when the trailing edge of the window sounds like a pause: its
    // energy has dropped well below the window's own average. Relative, not
    // absolute — mic gain and noise suppression move the floor around, but a
    // pause is always quiet compared to the speech before it.
    static func tailIsQuiet(_ window: [Float]) -> Bool {
        guard window.count >= tailSamples else { return false }
        let windowRMS = rms(window[...])
        // The whole window is effectively silent — cutting can't hurt.
        guard windowRMS > 1e-6 else { return true }
        return rms(window.suffix(tailSamples)) < 0.2 * windowRMS
    }

    private func compose(with confirmed: String) -> String {
        var parts = frozenChunks
        if !confirmed.isEmpty { parts.append(confirmed) }
        return parts.joined(separator: " ")
    }

    private static func rms<S: Sequence>(_ samples: S) -> Float where S.Element == Float {
        var sum: Float = 0
        var count = 0
        for s in samples {
            sum += s * s
            count += 1
        }
        guard count > 0 else { return 0 }
        return (sum / Float(count)).squareRoot()
    }
}
