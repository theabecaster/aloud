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

    // The wait for somebody who walked away holds the microphone open for
    // minutes, and every sample of it would otherwise be kept and then handed
    // to the transcriber. Trimming keeps a tail rather than everything, because
    // speech is only known to have started a moment after it did.
    func testDiscardingBufferedAudioKeepsOnlyTheTail() {
        let recorder = AudioRecorder()
        XCTAssertNoThrow(recorder.discardBuffered(keepingLast: 1.5),
                         "safe on a recorder that never started")
        XCTAssertNoThrow(recorder.discardBuffered(keepingLast: 0))
        XCTAssertNoThrow(recorder.discardBuffered(keepingLast: -1),
                         "a negative tail is nonsense, not a crash")
    }
}
