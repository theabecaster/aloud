import XCTest
@testable import Aloud

// The hands-free lock is panel state, and the panel outlives the session that
// set it: hiding the pill leaves the flag alone. The controller reads it back
// when a session's engine finishes spinning up, to carry over a lock that
// arrived during the wait — so a flag left set by the previous session would
// dress every following push-to-talk as hands-free (orange mic, stop button).
@MainActor
final class IndicatorLockTests: XCTestCase {

    // `showLocked()` only raises the flag — it does not put a pill on screen.
    // So every test that wants `hide()` to actually run has to show one first,
    // or `hide()` returns at its `guard let panel, isShowing` and the test
    // passes without reaching a line of the code it is named after.
    private func shownLockedPill() -> RecordingIndicatorPanel {
        let panel = RecordingIndicatorPanel()
        panel.show(levelProvider: { 0 })
        panel.showLocked()
        return panel
    }

    // A lock set on a pill that never reached the screen survives the `hide()`
    // that does nothing — which is why a new session clears the flag rather
    // than trusting hiding to have done it.
    func testLockOutlivesAHideThatHadNoPillToTakeDown() {
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

    // …and a pill that really was on screen takes the lock down with it, so the
    // next ordinary push-to-talk cannot inherit the orange mic and stop button.
    func testHidingAPillThatWasOnScreenClearsTheLock() {
        let panel = shownLockedPill()
        XCTAssertTrue(panel.isHandsFreeLocked)
        panel.hide()
        XCTAssertFalse(panel.isHandsFreeLocked,
                       "a pill that actually left the screen ended the session it belonged to")
    }

    func testClearingIsSafeWhenNoLockWasSet() {
        let panel = RecordingIndicatorPanel()
        panel.clearHandsFreeLock()
        XCTAssertFalse(panel.isHandsFreeLocked)
    }

    // The end-of-session cue hangs off a pill actually leaving the screen. A
    // pill that never arrived has nothing to announce — and `hide()` is called
    // liberally on paths that may never have shown one (a tap below the
    // model's minimum, a teardown), so sounding it here would put a "that's
    // over" chime on sessions the user never saw start.
    func testNoEndCueWhenThePillWasNeverOnScreen() {
        let panel = RecordingIndicatorPanel()
        var ended = 0
        panel.onHandsFreeEnd = { ended += 1 }
        panel.showLocked()
        panel.hide()
        panel.hide()
        XCTAssertEqual(ended, 0)
    }

    // The other half, and the one the test above cannot reach: a pill that WAS
    // on screen sounds the cue, exactly once, and does not lend it to the
    // session after it. `hide()` is called liberally — a teardown behind a
    // fade, a second path to the same end — so both the repeat and the
    // hand-over are ways one session's end could be announced twice.
    func testTheEndCueSoundsOncePerLockedSession() {
        let panel = shownLockedPill()
        var ended = 0
        panel.onHandsFreeEnd = { ended += 1 }

        panel.hide()
        XCTAssertEqual(ended, 1, "a locked pill leaving the screen announces itself")

        panel.hide()
        XCTAssertEqual(ended, 1, "and never twice for the one session")

        // The next session is an ordinary push-to-talk. A lock left standing
        // would put a "that's over" chime on a session the user never started
        // hands-free.
        panel.show(levelProvider: { 0 })
        panel.hide()
        XCTAssertEqual(ended, 1, "an unlocked session does not inherit the last one's cue")
    }
}

// The tick at the end of an agent turn, and the teardown that used to erase it.
//
// `sendDraft` is the moment the user's words go to the agent, and the
// checkmark it puts up is the only acknowledgement they get. `dismissConsent`
// forced the phase back to `.listening` unconditionally — and
// `endAgentSession` calls it on *every* teardown, prompt or no prompt, so the
// tick was overwritten microseconds after it appeared. The pill then fell
// through to the closed-microphone spinner and faded out still spinning, which
// is exactly what a hung turn looks like.
@MainActor
final class AgentTurnCompletionTests: XCTestCase {

    func testATeardownWithNoPromptOnScreenLeavesTheFinishedTurnAlone() {
        let panel = RecordingIndicatorPanel()
        panel.showAgentSession(session: "fixing tests", harness: "claude-code", lease: "L1")
        panel.sendDraft("fix it forward")
        XCTAssertEqual(panel.agentPhaseForTesting, .done, "the send puts the tick up")

        // Precisely what `endAgentSession` does, before it has even decided
        // whether anything of ours is still up.
        panel.dismissConsent()

        XCTAssertEqual(panel.agentPhaseForTesting, .done,
                       "no question was on screen, so there was nothing to dismiss")
    }

    // …and the case the parameter exists for still works: a prompt that really
    // was up leaves the pill in whatever comes next.
    func testDismissingARealPromptStillSetsThePhase() {
        let panel = RecordingIndicatorPanel()
        let now = Date()
        let prompt = ConsentPrompt(lease: "L1", harness: "claude-code", name: "fixing tests",
                                   mode: .confirmOnScreen,
                                   text: "Let fixing tests agent listen?",
                                   capture: .none,
                                   askedAt: now,
                                   deadline: now.addingTimeInterval(20))
        panel.showConsent(prompt: prompt, onAccept: {}, onDecline: {})
        XCTAssertEqual(panel.agentPhaseForTesting, .pending)

        panel.dismissConsent()

        XCTAssertEqual(panel.agentPhaseForTesting, .listening)
    }
}
