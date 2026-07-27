import XCTest
@testable import Aloud

final class SpeechActivityTests: XCTestCase {
    // Before the detector is downloaded (a fresh install still mid-setup) the
    // monitor has to stay silent rather than claim the room is quiet: nil is
    // what makes the pill fall back to its level threshold instead of
    // believing a detector that isn't there.
    func testReportsNothingWithoutADetector() {
        let activity = SpeechActivity()
        XCTAssertNil(activity.secondsSinceSpeech)
        activity.start()
        activity.append(samples: [Float](repeating: 0.2, count: 16_000))
        // Let the pump task run and find no detector.
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertNil(activity.secondsSinceSpeech)
        activity.stop()
        XCTAssertNil(activity.secondsSinceSpeech)
    }

    // Audio arrives on the tap thread; the pill reads from the main one. This
    // is a crash/deadlock guard, not a behaviour check.
    func testConcurrentAppendsAndReadsAreSafe() {
        let activity = SpeechActivity()
        activity.start()
        let chunk = [Float](repeating: 0.1, count: 512)
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            activity.append(samples: chunk)
            _ = activity.secondsSinceSpeech
        }
        activity.stop()
    }

    func testStoppingTwiceIsHarmless() {
        let activity = SpeechActivity()
        activity.start()
        activity.stop()
        activity.stop()
        XCTAssertNil(activity.secondsSinceSpeech)
    }
}
