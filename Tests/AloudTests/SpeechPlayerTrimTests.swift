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
    //
    // Pinned as "the tone survives and 0.06s of the silence with it" rather
    // than as `> 1.0`, which was true of the right answer (1.06), of no
    // trimming at all (1.5), and of everything in between — so the assertion
    // could not tell a working trim from an absent one.
    func testALittleSilenceIsKeptSoNothingIsClipped() {
        let trimmed = SpeechPlayer.trimmingTrailingSilence(speech(tone: 1.0, silence: 0.5))
        XCTAssertEqual(seconds(trimmed), 1.06, accuracy: 0.01,
                       "the audio itself is never touched, and a keepsafe rides with it")
    }

    // The boundary that actually decides whether a word gets clipped, and the
    // one the assertions above cannot reach: the floor is 1% of PEAK, not an
    // absolute level, so the quiet end of a word that trails off sits *below*
    // it and is only saved by the keepsafe. This is a word ending the way words
    // do — full volume, then eighty milliseconds falling away to half a percent
    // of the peak — and every sample of it has to come back.
    func testASoftlyDecayingWordEndingSurvivesTheFloor() {
        let toneCount = rate                       // one second of speech
        let decayFrom = toneCount - (rate * 8 / 100)   // the last 80 ms of it
        let word = (0..<toneCount).map { i -> Float in
            let amplitude: Float
            if i < decayFrom {
                amplitude = 0.8
            } else {
                let progress = Float(i - decayFrom) / Float(toneCount - decayFrom)
                amplitude = 0.8 * pow(0.005, progress)   // 0.8 → 0.004, under the floor
            }
            return sin(Float(i) * 0.05) * amplitude
        }
        let speech = Speech(samples: word + [Float](repeating: 0, count: rate / 2),
                            sampleRate: rate, synthesisTime: 0)

        let trimmed = SpeechPlayer.trimmingTrailingSilence(speech)

        XCTAssertGreaterThanOrEqual(trimmed.samples.count, toneCount,
                                    "the quiet end of the word was cut off — it is still speech")
        // …and the half second of digital silence after it still goes, so the
        // trim did the job it is there for rather than giving up on the clip.
        XCTAssertLessThan(seconds(trimmed), 1.1,
                          "the padding should not have survived alongside the word")
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
