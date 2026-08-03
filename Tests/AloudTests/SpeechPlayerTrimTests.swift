import XCTest
@testable import Aloud

// Synthesizers pad their output, and playback completes on `.dataPlayedBack` —
// the whole buffer, silence included. Measured for one sentence on this Mac:
// kokoro 0.43s of trailing silence, supertonic 0.36s, pocket 0.12s, the system
// voice 0.04s. Every one of those is time `isPlaying` stays true after the
// voice has audibly stopped, so the pill keeps drawing the talking animation
// and the microphone opens later than it had to.
final class SpeechPlayerTrimTests: XCTestCase {

    private let rate = 24_000

    private func speech(tone: TimeInterval, silence: TimeInterval) -> Speech {
        let toneCount = Int(tone * Double(rate))
        let samples = (0..<toneCount).map { i in sin(Float(i) * 0.05) * 0.8 }
            + [Float](repeating: 0, count: Int(silence * Double(rate)))
        return Speech(samples: samples, sampleRate: rate, synthesisTime: 0)
    }

    private func seconds(_ speech: Speech) -> TimeInterval {
        Double(speech.samples.count) / Double(speech.sampleRate)
    }

    func testTrailingSilenceIsRemoved() {
        let trimmed = SpeechPlayer.trimmingTrailingSilence(speech(tone: 2.0, silence: 0.43))
        // The tone plus the deliberate 0.06s of keepsafe, and nothing else.
        XCTAssertEqual(seconds(trimmed), 2.06, accuracy: 0.01)
    }

    // The point of keeping a tail: a word that ends softly must not be clipped,
    // and being wrong in this direction costs nothing but a few milliseconds.
    func testALittleSilenceIsKeptSoNothingIsClipped() {
        let trimmed = SpeechPlayer.trimmingTrailingSilence(speech(tone: 1.0, silence: 0.5))
        XCTAssertGreaterThan(seconds(trimmed), 1.0, "the audio itself is never touched")
    }

    // Audio that runs to its last sample is handed back untouched rather than
    // having its final frames shaved off.
    func testSpeechWithNoTrailingSilenceIsLeftAlone() {
        let original = speech(tone: 1.5, silence: 0)
        let trimmed = SpeechPlayer.trimmingTrailingSilence(original)
        XCTAssertEqual(trimmed.samples.count, original.samples.count)
    }

    // Nothing to trim, and nothing to play. It must come back as it went in
    // rather than as an empty buffer, which `play` would silently drop.
    func testDigitalSilenceIsNotTrimmedAway() {
        let silent = Speech(samples: [Float](repeating: 0, count: rate),
                            sampleRate: rate, synthesisTime: 0)
        XCTAssertEqual(SpeechPlayer.trimmingTrailingSilence(silent).samples.count, rate)
    }

    func testEmptySpeechIsHarmless() {
        let empty = Speech(samples: [], sampleRate: rate, synthesisTime: 0)
        XCTAssertTrue(SpeechPlayer.trimmingTrailingSilence(empty).samples.isEmpty)
    }
}
