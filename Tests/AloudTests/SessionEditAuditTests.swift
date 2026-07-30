import XCTest
@testable import Aloud

final class SessionEditAuditTests: XCTestCase {

    private func type(_ text: String) -> [EditTracker.Input] {
        text.map { .text(String($0)) }
    }

    func testUntouchedSessionLearnsNothing() {
        var audit = SessionEditAudit()
        for input in type("say hi to John Smith") { audit.consumeSynthetic(input) }
        let c = audit.conclude()
        XCTAssertFalse(audit.userTouched)
        XCTAssertTrue(c.candidates.isEmpty)
        XCTAssertNil(c.screenText)
    }

    func testMidDictationKeyboardFixIsCaught() {
        var audit = SessionEditAudit()
        // Aloud types the preview, the user backspaces the name and retypes
        // it, Aloud keeps appending as they continue speaking.
        for input in type("say hi to John Smith") { audit.consumeSynthetic(input) }
        for input in [EditTracker.Input.backspace, .backspace, .backspace, .backspace, .backspace]
            + type("Smyth") { audit.consumeUser(input) }
        for input in type(" thanks") { audit.consumeSynthetic(input) }
        let c = audit.conclude()
        XCTAssertEqual(c.candidates, [CorrectionDiff.Candidate(from: "Smith", to: "Smyth")])
        XCTAssertEqual(c.screenText, "say hi to John Smyth thanks")
    }

    func testMidDictationClickFixBecomesABurstMatch() {
        var audit = SessionEditAudit()
        for input in type("say hi to John Smith for me") { audit.consumeSynthetic(input) }
        audit.consumeUser(.click)
        for input in type("Smyth") { audit.consumeUser(input) }
        let c = audit.conclude()
        XCTAssertEqual(c.candidates, [CorrectionDiff.Candidate(from: "Smith", to: "Smyth")])
        // Position went unknowable — the screen text cannot be claimed.
        XCTAssertNil(c.screenText)
    }

    func testSyntheticTypingNeverPollutesABurst() {
        var audit = SessionEditAudit()
        for input in type("call Marc today") { audit.consumeSynthetic(input) }
        audit.consumeUser(.click)
        for input in type("Mark") { audit.consumeUser(input) }
        // Aloud keeps typing the next phrase while the user's cursor is
        // somewhere unknowable: it must cut the burst, not join it.
        for input in type(" and tomorrow") { audit.consumeSynthetic(input) }
        for input in type("!!") { audit.consumeUser(input) }
        let c = audit.conclude()
        XCTAssertEqual(c.candidates, [CorrectionDiff.Candidate(from: "Marc", to: "Mark")])
    }

    func testAloudRewindingItsOwnPreviewIsNotAnEdit() {
        var audit = SessionEditAudit()
        // The live preview retypes its tail as the transcript stabilizes.
        for input in type("say hight") { audit.consumeSynthetic(input) }
        for input in [EditTracker.Input.backspace, .backspace, .backspace] + type(" to John")
            { audit.consumeSynthetic(input) }
        let c = audit.conclude()
        XCTAssertFalse(audit.userTouched)
        XCTAssertTrue(c.candidates.isEmpty)
    }

    func testUserAdditionsAloneAreNoCandidates() {
        var audit = SessionEditAudit()
        for input in type("send the report") { audit.consumeSynthetic(input) }
        for input in type(" today") { audit.consumeUser(input) }
        let c = audit.conclude()
        // Pure insertion: real user text, but no substitution to learn.
        XCTAssertTrue(c.candidates.isEmpty)
        XCTAssertEqual(c.screenText, "send the report today")
    }
}
