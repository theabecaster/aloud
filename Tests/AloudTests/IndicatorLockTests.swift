import XCTest
@testable import Aloud

// The hands-free lock is panel state, and the panel outlives the session that
// set it: hiding the pill leaves the flag alone. The controller reads it back
// when a session's engine finishes spinning up, to carry over a lock that
// arrived during the wait — so a flag left set by the previous session would
// dress every following push-to-talk as hands-free (orange mic, stop button).
@MainActor
final class IndicatorLockTests: XCTestCase {

    func testLockOutlivesTheHiddenPill() {
        let panel = RecordingIndicatorPanel()
        panel.showLocked()
        panel.hide()
        XCTAssertTrue(panel.isHandsFreeLocked,
                      "hiding does not end the lock — which is why a new session must clear it")
    }

    func testAFreshSessionStartsUnlocked() {
        let panel = RecordingIndicatorPanel()
        panel.showLocked()
        panel.hide()
        panel.clearHandsFreeLock()
        XCTAssertFalse(panel.isHandsFreeLocked)
    }

    func testClearingIsSafeWhenNoLockWasSet() {
        let panel = RecordingIndicatorPanel()
        panel.clearHandsFreeLock()
        XCTAssertFalse(panel.isHandsFreeLocked)
    }
}
