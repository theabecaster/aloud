import XCTest
@testable import Aloud

// The "Still listening…" rule behind a locked hands-free session. What changed
// with speech detection is *what feeds it* — seconds since real speech instead
// of seconds since the input level dipped — so these pin the behaviour that has
// to survive that swap.
final class SilenceReminderTests: XCTestCase {
    private typealias Rule = RecordingIndicatorPanel.SilenceReminder

    private func next(showing: Bool = false,
                      silentFor: TimeInterval,
                      lockedFor: TimeInterval = 3_600,
                      isLocked: Bool = true,
                      inputIdle: TimeInterval = 60) -> Bool {
        Rule.next(showing: showing, silentFor: silentFor, lockedFor: lockedFor,
                  isLocked: isLocked, inputIdle: { inputIdle })
    }

    func testAppearsAfterALongSilenceWhileAway() {
        XCTAssertTrue(next(silentFor: 45))
    }

    func testStaysAwayWhileSomeoneIsTalking() {
        XCTAssertFalse(next(silentFor: 0))
        XCTAssertFalse(next(silentFor: 0.2))
    }

    func testStaysAwayBeforeTheThreshold() {
        XCTAssertFalse(next(silentFor: 29))
    }

    // Push-to-talk holds never get the reminder; only a locked session can.
    func testUnlockedSessionsNeverRemind() {
        XCTAssertFalse(next(silentFor: 300, isLocked: false))
        XCTAssertFalse(next(showing: true, silentFor: 300, isLocked: false))
    }

    // Someone typing or mousing is present, not away — no nudge.
    func testBusyUserIsNotInterrupted() {
        XCTAssertFalse(next(silentFor: 300, inputIdle: 1))
    }

    // Locking a session that had already been quiet starts the clock at the
    // lock, so the pill doesn't nag the instant it locks.
    func testClockStartsAtTheLock() {
        XCTAssertFalse(next(silentFor: 300, lockedFor: 2))
        XCTAssertTrue(next(silentFor: 300, lockedFor: 31))
    }

    // Once shown it latches: only speech takes it back down, so a stray mouse
    // twitch can't flicker the caption at 30 Hz.
    func testLatchesUntilSpeechReturns() {
        XCTAssertTrue(next(showing: true, silentFor: 45, inputIdle: 0))
        XCTAssertTrue(next(showing: true, silentFor: 31, lockedFor: 0.1))
        XCTAssertFalse(next(showing: true, silentFor: 0.1))
    }
}
