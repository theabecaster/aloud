import XCTest
@testable import Aloud

// The envelope is what makes the speaking indicator show *this* sentence
// rather than a generic wiggle, so its edges matter: it is read at display
// rate from a drawing that must never stall, and it is built from whatever an
// engine hands us — including, occasionally, nothing at all.
final class SpeechEnvelopeTests: XCTestCase {
    func testSilenceProducesNoLevelsRatherThanDividingByZero() {
        let envelope = SpeechEnvelope(samples: [Float](repeating: 0, count: 16_000),
                                      sampleRate: 16_000)
        XCTAssertEqual(envelope.level(at: 0), 0)
        XCTAssertEqual(envelope.level(at: 0.5), 0)
    }

    func testAnEmptyUtteranceIsEmpty() {
        XCTAssertTrue(SpeechEnvelope(samples: [], sampleRate: 16_000).isEmpty)
        // A nonsense sample rate must not produce a divide, an infinite frame
        // count, or a crash.
        XCTAssertTrue(SpeechEnvelope(samples: [0.1, 0.2], sampleRate: 0).isEmpty)
    }

    // Normalized to the utterance's own peak: this drives a picture of someone
    // talking, so a quiet sentence has to look like speech rather than like
    // silence. The loudest moment reaches the top whatever the volume.
    func testLoudestMomentReachesFullScaleWhateverTheVolume() {
        for amplitude in [Float(1.0), 0.2, 0.02] {
            let samples = (0..<16_000).map { i -> Float in
                i < 8_000 ? amplitude : amplitude / 4
            }
            let envelope = SpeechEnvelope(samples: samples, sampleRate: 16_000)
            XCTAssertEqual(envelope.level(at: 0.1), 1.0, accuracy: 0.01,
                           "amplitude \(amplitude): the peak of the utterance is full scale")
            XCTAssertEqual(envelope.level(at: 0.75), 0.25, accuracy: 0.02,
                           "amplitude \(amplitude): a quarter as loud reads a quarter as tall")
        }
    }

    // Read past the end and it settles rather than freezing on the last frame:
    // the drawing polls on its own clock and will always overrun playback by
    // some fraction of a frame.
    func testReadingPastTheEndIsSilentNotStuck() {
        let envelope = SpeechEnvelope(samples: [Float](repeating: 0.5, count: 16_000),
                                      sampleRate: 16_000)
        XCTAssertEqual(envelope.level(at: 0.5), 1.0, accuracy: 0.01)
        XCTAssertEqual(envelope.level(at: 5), 0, "past the utterance there is nothing to draw")
        XCTAssertEqual(envelope.level(at: -1), 0, "and nothing before it either")
    }
}
