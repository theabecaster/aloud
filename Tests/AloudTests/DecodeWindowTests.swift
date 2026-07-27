import XCTest
@testable import Aloud

// The speech model decodes only as many frames as the audio it was handed, and
// that bound changes what comes back — the same recording at 14 s lost its
// opening sentence while 13 s and 15 s were complete. Filling the window makes
// every dictation take the same path, so the answer stops depending on how
// long the key happened to be held.
final class DecodeWindowTests: XCTestCase {
    private let window = 240_000   // 15 s at 16 kHz — the model's window

    func testShortAudioFillsTheWindow() {
        for seconds in [0.5, 2.0, 12.0, 14.0] {
            let samples = [Float](repeating: 0.3, count: Int(seconds * 16_000))
            XCTAssertEqual(ParakeetTranscriber.decodeWindow(samples).count, window,
                           "\(seconds)s should be padded to the full window")
        }
    }

    func testTheSpeechItselfIsUntouched() {
        let spoken = (0..<16_000).map { Float($0) / 16_000 }
        let padded = ParakeetTranscriber.decodeWindow(spoken)
        XCTAssertEqual(Array(padded.prefix(spoken.count)), spoken)
        // Everything added is silence, not a repeat of the audio.
        XCTAssertTrue(padded.dropFirst(spoken.count).allSatisfy { $0 == 0 })
    }

    // Longer audio is the engine's own chunking problem; padding it would only
    // add a chunk of silence.
    func testLongAudioIsLeftAlone() {
        let long = [Float](repeating: 0.1, count: window + 5_000)
        XCTAssertEqual(ParakeetTranscriber.decodeWindow(long).count, long.count)
        let exact = [Float](repeating: 0.1, count: window)
        XCTAssertEqual(ParakeetTranscriber.decodeWindow(exact).count, window)
    }
}
