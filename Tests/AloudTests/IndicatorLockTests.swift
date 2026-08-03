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
