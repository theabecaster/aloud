import XCTest
@testable import Aloud

// A consent prompt owns the keyboard while it is up.
//
// Found by hand, in mode 2, where there is no spoken answer to fall back on:
// pressing the Aloud hotkey to accept — which the pill's own tooltip tells you
// to do — started an ordinary dictation on top of the pending question. Two
// claimants on one microphone, words typed into whatever app was focused, and
// the agent left waiting until it timed out on an answer the keyboard could
// not give.
final class ConsentKeysTests: XCTestCase {
    private let everyAction: [HotkeyAction] = [
        .begin, .commit, .cancel, .lock, .beginCommand, .commitCommand, .cancelCommand,
    ]

    // With nothing being asked, the prompt logic is invisible: dictation
    // behaves exactly as it always has. This is the guard against the fix
    // leaking into the feature the app is actually for.
    func testWithNoPromptEveryActionPassesThroughUntouched() {
        for action in everyAction {
            let outcome = ConsentKeys.translate(action, consentIsPending: false)
            XCTAssertEqual(outcome.emit, action, "\(action) must be unchanged when nothing is asking")
            XCTAssertFalse(outcome.consumed, "\(action) must still reach the app underneath")
        }
        XCTAssertNil(ConsentKeys.translate(.none, consentIsPending: false).emit)
    }

    // Any way of starting to talk to Aloud, while Aloud is asking a yes/no
    // question, is the answer to that question.
    func testAnythingThatWouldStartRecordingAnswersYesInstead() {
        for action in [HotkeyAction.begin, .lock, .beginCommand] {
            let outcome = ConsentKeys.translate(action, consentIsPending: true)
            XCTAssertEqual(outcome.emit, .consentAccept, "\(action) must accept, not record")
            XCTAssertTrue(outcome.consumed, "a keystroke that answered an agent must not also reach the app")
        }
    }

    func testEscapeDeclines() {
        for action in [HotkeyAction.cancel, .cancelCommand] {
            let outcome = ConsentKeys.translate(action, consentIsPending: true)
            XCTAssertEqual(outcome.emit, .consentDecline)
            XCTAssertTrue(outcome.consumed)
        }
    }

    // The release half of the press that just answered. Nothing was recorded,
    // so there is nothing to commit — and committing here would hand the
    // dictation path an empty session behind the user's back.
    func testTheReleaseOfTheAnsweringPressDoesNothing() {
        for action in [HotkeyAction.commit, .commitCommand] {
            let outcome = ConsentKeys.translate(action, consentIsPending: true)
            XCTAssertNil(outcome.emit, "\(action) must not reach the controller")
            XCTAssertTrue(outcome.consumed)
        }
    }

    // The invariant behind all of the above, stated once: while a prompt is
    // up, nothing that starts or commits a recording may escape.
    func testNoRecordingActionSurvivesAPendingPrompt() {
        for action in everyAction {
            let emitted = ConsentKeys.translate(action, consentIsPending: true).emit
            XCTAssertTrue(emitted == nil || emitted == .consentAccept || emitted == .consentDecline,
                          "\(action) leaked to the dictation path as \(String(describing: emitted))")
        }
    }
}
