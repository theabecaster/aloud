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

    private struct RendererNeverFinished: Error {}

    // Lets the watchdog below reach across to `stop()` without the player
    // itself having to be Sendable. Stopping is the one call on it that is safe
    // from anywhere: it guards on `wired` and forwards to the node, which does
    // its own locking.
    private final class Stopper: @unchecked Sendable {
        private let player: SpeechPlayer
        init(_ player: SpeechPlayer) { self.player = player }
        func stop() { player.stop() }
    }

    // `play` resolves on `.dataPlayedBack`, which a null renderer on a machine
    // with no output device may simply never deliver — so the await has a
    // ceiling. Without it CI does not fail here, it *hangs*: `engine.start()`
    // succeeds against a null device, the buffer is accepted, the callback
    // never fires, and the job runs to the workflow timeout with no idea why.
    // `stop()` fires the pending completion, so the watchdog unblocks the
    // await rather than leaving it and the test both stuck.
    private func timePlaying(_ player: SpeechPlayer, _ speech: Speech,
                             within ceiling: TimeInterval = 5) async throws -> TimeInterval {
        let started = Date()
        let stopper = Stopper(player)
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(ceiling * 1_000_000_000))
            stopper.stop()
        }
        defer { watchdog.cancel() }
        try await player.play(speech)
        let elapsed = Date().timeIntervalSince(started)
        if elapsed >= ceiling { throw RendererNeverFinished() }
        return elapsed
    }

    func testPlaysAgainAfterBeingStopped() async throws {
        let player = SpeechPlayer()
        let clip = silence(seconds: 0.3)

        // Every play is inside the skip, not just the first. A runner can start
        // the engine and still have nothing behind it, and the failure then
        // lands on the second or third clip — where it was an error rather than
        // a skip, and reported as a broken player rather than a bare machine.
        let first: TimeInterval
        let second: TimeInterval
        let third: TimeInterval
        do {
            first = try await timePlaying(player, clip)
            // The sequence the preview button uses: stop what's talking, then
            // talk.
            player.stop()
            second = try await timePlaying(player, clip)
            // And again, because the failure was permanent once it started.
            player.stop()
            third = try await timePlaying(player, clip)
        } catch {
            // No audio hardware (a bare CI runner). Nothing to assert about
            // playback that can't happen at all.
            throw XCTSkip("no usable output device: \(error)")
        }

        XCTAssertGreaterThan(first, 0.2, "the first clip didn't play")
        XCTAssertGreaterThan(second, 0.2,
                             "playback after a stop returned instantly — nothing was heard")
        XCTAssertGreaterThan(third, 0.2, "the third clip didn't play")
    }
}
