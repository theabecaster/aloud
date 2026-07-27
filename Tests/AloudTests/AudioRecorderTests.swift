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
}
