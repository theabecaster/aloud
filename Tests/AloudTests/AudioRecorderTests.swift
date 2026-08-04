import AVFoundation
import XCTest
@testable import Aloud

final class AudioRecorderTests: XCTestCase {
    // The MacBook Pro's built-in microphone presents three channels. Folding
    // that to mono without naming a channel yields digital silence — no error,
    // no warning, just a dictation that comes back empty. Measured on this
    // Mac: 0 of 30,197 samples non-zero without a map, 29,759 of 31,813 with
    // one.
    func testMultichannelInputPicksAChannel() {
        XCTAssertEqual(AudioRecorder.channelMap(forInputChannels: 3), [0])
        XCTAssertEqual(AudioRecorder.channelMap(forInputChannels: 2), [0])
    }

    // An ordinary mono microphone needs no help, and forcing a map on it would
    // be a change with nothing to gain.
    func testMonoInputIsLeftAlone() {
        XCTAssertNil(AudioRecorder.channelMap(forInputChannels: 1))
    }

    // A stop that had nothing to stop leaves the callbacks alone.
    //
    // The half that cannot be asserted here is the one that matters, and it is
    // worth saying where somebody will read it: a stop that *was* recording
    // drops `onChunk` and `onMonitorChunk` with the engine, so anything that
    // starts capture again has to hand them back. Forgetting costs nothing
    // visible — no error, no crash — and everything real: an agent session that
    // restarts capture mid-listen feeds the speech detector silence from then
    // on, so the pill sits saying "Waiting" with the microphone genuinely open
    // while the user talks at it for ten minutes and the detector, which is the
    // thing that decides anybody spoke, hears not one sample. Proving it needs
    // a live engine and a microphone grant, which is `--mic-check`'s job.
    func testStopOnARecorderThatNeverStartedIsANoOp() {
        let recorder = AudioRecorder()
        recorder.onChunk = { _ in }
        recorder.onMonitorChunk = { _ in }

        XCTAssertEqual(recorder.stop(), [])
        XCTAssertNotNil(recorder.onChunk)
        XCTAssertNotNil(recorder.onMonitorChunk)
    }

    // Trimming an empty buffer, which is every argument's answer here.
    //
    // Named for what it proves, which is not what the trim is *for*. The tail
    // that `discardBuffered` keeps — the thing standing between a ten-minute
    // agent hold and ten minutes of room tone reaching the transcriber — cannot
    // be reached from a test: the recorder's sample buffer is `private`, the
    // only thing that ever appends to it is the private capture callback, and
    // filling it needs a live engine and a microphone grant. So every call
    // below returns at `guard samples.count > keep` no matter what it is
    // handed, including `keepingLast: 0`, and this test would pass just as well
    // against a `discardBuffered` that did nothing at all.
    //
    // It is kept because a crash on an unstarted recorder is a real thing to
    // rule out — `removeFirst` on an empty array traps — and it is named
    // honestly so nobody reads the trim as covered. Covering it properly wants
    // a pure `AudioRecorder.keepingTail(_:seconds:sampleRate:)` that both the
    // recorder and a test can call; the arithmetic is four lines and none of it
    // needs audio.
    func testDiscardingBufferedAudioOnARecorderThatNeverStartedIsANoOp() {
        let recorder = AudioRecorder()
        recorder.discardBuffered(keepingLast: 1.5)
        recorder.discardBuffered(keepingLast: 0)
        // A negative tail is nonsense, not a crash: `keep` clamps to zero and
        // the guard above it does the rest.
        recorder.discardBuffered(keepingLast: -1)
        // Deliberately NOT `.infinity` or `.nan`. Both trap, in
        // `Int(seconds * targetSampleRate)`, before the clamp can see them —
        // verified by adding them here and watching the runner die on
        // "Double value cannot be converted to Int". Unreachable today (both
        // call sites pass a constant), so it is a latent trap rather than a
        // live bug, and asserting a robustness the code does not offer would
        // just be a red test.
        XCTAssertEqual(recorder.stop(), [], "nothing was captured, so nothing comes back")
    }
    // The trim itself, through the pure form of it. Reaching it through a
    // recorder needs a live microphone — the buffer is private and only the
    // audio tap writes it — which is why the test above can only prove the
    // no-op case.
    //
    // What this protects: an agent holding the microphone for somebody who
    // walked away records the empty room the whole time, and all of it would be
    // handed to the transcriber to read one sentence out of. The tail is what
    // makes discarding safe at all: capture cannot start the instant somebody
    // speaks, so keeping the recent past means the first word survives.
    func testKeepingTailKeepsExactlyTheTail() {
        let rate = 16_000.0
        let tenSeconds = [Float](repeating: 0.5, count: Int(10 * rate))

        let kept = AudioRecorder.keepingTail(tenSeconds, seconds: 2, sampleRate: rate)
        XCTAssertEqual(kept.count, Int(2 * rate), "two seconds of a ten-second buffer")

        XCTAssertEqual(AudioRecorder.keepingTail(tenSeconds, seconds: 0, sampleRate: rate).count, 0,
                       "keeping nothing keeps nothing")
        XCTAssertEqual(AudioRecorder.keepingTail(tenSeconds, seconds: 30, sampleRate: rate).count,
                       tenSeconds.count,
                       "asking for more than there is keeps what there is")
    }

    // It is the *end* that survives, not the beginning: the tail is the audio
    // closest to the moment somebody started talking.
    func testKeepingTailKeepsTheEndAndNotTheStart() {
        let rate = 100.0
        let ramp = (0..<200).map { Float($0) }
        let kept = AudioRecorder.keepingTail(ramp, seconds: 1, sampleRate: rate)
        XCTAssertEqual(kept.count, 100)
        XCTAssertEqual(kept.first, 100, "the tail starts where the discarded part ends")
        XCTAssertEqual(kept.last, 199, "and runs to the newest sample")
    }

    // `Int(_: Double)` traps on these, and it converts before any clamp can see
    // them. Asking to keep an infinite tail means keeping everything, not
    // taking the process down.
    func testKeepingTailSurvivesAnUnusableDuration() {
        let samples = [Float](repeating: 0.1, count: 1_000)
        XCTAssertEqual(AudioRecorder.keepingTail(samples, seconds: .infinity).count, 1_000)
        XCTAssertEqual(AudioRecorder.keepingTail(samples, seconds: .nan).count, 1_000)
        XCTAssertEqual(AudioRecorder.keepingTail(samples, seconds: -5).count, 0,
                       "a negative tail is no tail, not a crash")
    }
}
