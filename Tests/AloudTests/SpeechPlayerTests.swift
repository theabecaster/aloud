import XCTest
@testable import Aloud

// Playing twice, with a stop in between, has to actually play twice.
//
// This exists because it did not. The preview button stops whatever is
// speaking before it speaks again — two samples overlapping is worse than one
// cut short — and after that stop every later utterance came back instantly
// and silently: the button flicked to Stop and straight back to Play, at every
// speed, for the rest of the session. The cause is in the layer below, so the
// test is too.
//
// Silence is used as the audio, so this makes no noise: the path being checked
// is the scheduling, not the sound.
final class SpeechPlayerTests: XCTestCase {

    private func silence(seconds: Double) -> Speech {
        let rate = 24_000
        return Speech(samples: [Float](repeating: 0, count: Int(Double(rate) * seconds)),
                      sampleRate: rate, synthesisTime: 0)
    }

    private func timePlaying(_ player: SpeechPlayer, _ speech: Speech) async throws -> TimeInterval {
        let started = Date()
        try await player.play(speech)
        return Date().timeIntervalSince(started)
    }

    func testPlaysAgainAfterBeingStopped() async throws {
        let player = SpeechPlayer()
        let clip = silence(seconds: 0.3)

        let first: TimeInterval
        do {
            first = try await timePlaying(player, clip)
        } catch {
            // No audio hardware (a bare CI runner). Nothing to assert about
            // playback that can't happen at all.
            throw XCTSkip("no output device: \(error)")
        }
        XCTAssertGreaterThan(first, 0.2, "the first clip didn't play")

        // The sequence the preview button uses: stop what's talking, then talk.
        player.stop()
        let second = try await timePlaying(player, clip)
        XCTAssertGreaterThan(second, 0.2,
                             "playback after a stop returned instantly — nothing was heard")

        // And again, because the failure was permanent once it started.
        player.stop()
        let third = try await timePlaying(player, clip)
        XCTAssertGreaterThan(third, 0.2, "the third clip didn't play")
    }
}
