import Foundation

// The shape of an utterance over time: how loud it is at each moment.
//
// Built from the samples we are about to play, before we play them. Nothing
// taps the output graph to get this — that graph is what the half-duplex gate
// is built on, and it is not worth disturbing to animate a pill. We already
// hold the whole waveform, and we know when playback started, so the level at
// any instant is a lookup rather than a measurement.
//
// Normalized to the utterance's own peak on purpose. This drives a picture of
// someone talking, so what matters is the rhythm of the speech — the shape of
// words and the gaps between them — not how loud the Mac's volume happens to
// be. A quiet sentence should look like speech, not like silence.
struct SpeechEnvelope: Equatable {
    // Frames per second of envelope. Comfortably above display refresh, so the
    // drawing interpolates between frames rather than stepping through them.
    static let frameRate: Double = 60

    private let frames: [Float]

    var isEmpty: Bool { frames.isEmpty }

    // For tests and for callers that already have an envelope in hand.
    init(frames: [Float]) {
        self.frames = frames
    }

    init(samples: [Float], sampleRate: Int) {
        guard sampleRate > 0, !samples.isEmpty else {
            self.frames = []
            return
        }
        let perFrame = max(1, Int(Double(sampleRate) / Self.frameRate))
        var built: [Float] = []
        built.reserveCapacity(samples.count / perFrame + 1)
        var index = 0
        var peak: Float = 0
        while index < samples.count {
            let end = min(index + perFrame, samples.count)
            // RMS rather than peak per frame: peak follows single clicks and
            // makes the drawing twitch, RMS follows the voice.
            var sum: Float = 0
            for i in index..<end { sum += samples[i] * samples[i] }
            let rms = (sum / Float(end - index)).squareRoot()
            built.append(rms)
            if rms > peak { peak = rms }
            index = end
        }
        // A silent buffer normalizes to nothing rather than dividing by zero
        // and drawing garbage.
        self.frames = peak > 0 ? built.map { $0 / peak } : built
    }

    // 0…1 at `elapsed` seconds into playback. Past the end — and before the
    // start — it is silent, so an animation reading a stale envelope settles
    // instead of freezing mid-word.
    func level(at elapsed: TimeInterval) -> Float {
        guard !frames.isEmpty, elapsed >= 0 else { return 0 }
        let index = Int(elapsed * Self.frameRate)
        guard index < frames.count else { return 0 }
        return frames[index]
    }
}
