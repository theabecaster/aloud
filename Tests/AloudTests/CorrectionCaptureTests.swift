import XCTest
@testable import Aloud

final class CorrectionCaptureTests: XCTestCase {
    private func span(_ injected: String, in fieldText: String) -> String? {
        CorrectionCapture.editedSpan(injected: injected, fieldText: fieldText)
    }

    // MARK: unchanged

    func testUnchangedTextYieldsNil() {
        let text = "Please send the report to the finance team today."
        XCTAssertNil(span(text, in: text))
    }

    func testUnchangedEmbeddedInDocumentYieldsNil() {
        let injected = "Please send the report to the finance team today."
        let field = "Notes from standup.\n\n\(injected)\n\nNext item: hiring."
        XCTAssertNil(span(injected, in: field))
    }

    func testWhitespaceOnlyDifferenceYieldsNil() {
        XCTAssertNil(span("send the weekly report today",
                          in: "send the  weekly\nreport today"))
    }

    func testTypingAfterInjectionYieldsNil() {
        // The commonest sequence: dictate, then keep typing. The appended
        // text is new prose, not an edit of the dictation.
        let injected = "I will meet John at noon on Thursday"
        XCTAssertNil(span(injected,
                          in: injected + " Let me know if that works for you."))
    }

    // MARK: degenerate inputs

    func testEmptyInputsYieldNil() {
        XCTAssertNil(span("", in: "some field text here"))
        XCTAssertNil(span("some injected text here", in: ""))
        XCTAssertNil(span("", in: ""))
    }

    func testPunctuationOnlyInjectionYieldsNil() {
        XCTAssertNil(span("— … !!", in: "hello there friend"))
    }

    func testFieldTextTooShortYieldsNil() {
        XCTAssertNil(span("this dictation had quite a few words in it", in: "ok"))
    }

    func testInjectionFullyDeletedYieldsNil() {
        XCTAssertNil(span("the quarterly numbers look great overall",
                          in: "Meeting notes about staffing plans and hiring for next year."))
    }

    // MARK: size bounds

    func testOverlongInjectionBailsOut() {
        // Would be a clean single-word fix if it weren't over the word cap.
        let words = (0..<121).map { "word\($0)" }
        var edited = words
        edited[5] = "changed"
        XCTAssertNil(span(words.joined(separator: " "),
                          in: edited.joined(separator: " ")))
    }

    func testOverlongFieldTextBailsOut() {
        let filler = (0..<600).map { "filler\($0)" }.joined(separator: " ")
        XCTAssertNil(span("alpha beta gamma delta",
                          in: filler + " alpha beta gamma echo"))
    }

    // MARK: single fixes

    func testSingleWordNameFixMidText() {
        let injected = "please email jon smith about the offsite agenda"
        let field = "Reminder list.\nplease email jon smyth about the offsite agenda\nAlso: book travel."
        XCTAssertEqual(span(injected, in: field),
                       "please email jon smyth about the offsite agenda")
    }

    func testCaseOnlyEditReturnsSpan() {
        let injected = "meet jon smith at noon"
        let field = "Agenda item one. meet Jon Smith at noon Agenda item two."
        XCTAssertEqual(span(injected, in: field), "meet Jon Smith at noon")
    }

    func testPunctuationOnlyEditReturnsSpanWithoutCrashing() {
        let injected = "Hello world how are you"
        XCTAssertEqual(span(injected, in: "Hello, world! How are you?"),
                       "Hello, world! How are you?")
    }

    // MARK: insertions and deletions inside the passage

    func testWordInsertedInsideIsPartOfSpan() {
        let injected = "send the draft to marketing"
        let field = "send the revised draft to marketing"
        XCTAssertEqual(span(injected, in: field), field)
    }

    func testWordDeletedInsideIsReflectedInSpan() {
        let injected = "send the revised draft to marketing"
        let field = "Intro. send the draft to marketing Outro."
        XCTAssertEqual(span(injected, in: field), "send the draft to marketing")
    }

    // MARK: position in a larger document

    func testInjectionAtDocumentStart() {
        let injected = "our demo for the acme team went well"
        let field = "our demo for the ACME team went well. Additional notes about other unrelated topics follow here."
        XCTAssertEqual(span(injected, in: field),
                       "our demo for the ACME team went well.")
    }

    func testInjectionInDocumentMiddle() {
        let injected = "please loop in sarah chen on the thread going forward"
        let field = "Preamble sentence first. please loop in Sara Chen on the thread going forward. Trailing sentence last."
        XCTAssertEqual(span(injected, in: field),
                       "please loop in Sara Chen on the thread going forward.")
    }

    func testInjectionAtEndOfLongEmail() {
        let body = """
        Hi team,

        Thanks for the patience while we sorted out the vendor contract. \
        The final numbers came back better than expected and legal has \
        signed off on the remaining clauses. Next week we will walk \
        through the rollout plan and assign owners for each workstream.

        """
        let injected = "thanks again for the quick turnaround on the contract"
        let field = body + "thanks again for the speedy turnaround on the contract"
        XCTAssertEqual(span(injected, in: field),
                       "thanks again for the speedy turnaround on the contract")
    }

    func testMultiParagraphInjectionKeepsParagraphBreak() {
        let injected = "First we cover the budget review for the quarter.\n\nSecond we walk through the hiring plan together."
        let field = "First we cover the budget review for the quarter.\n\nSecond we walk through the staffing plan together."
        XCTAssertEqual(span(injected, in: field), field)
    }

    // MARK: refusing to guess

    func testHeavyRewriteYieldsNil() {
        XCTAssertNil(span("let us grab lunch at the taco place tomorrow",
                          in: "I rescheduled our lunch to Thursday at the sushi spot"))
    }

    func testClippedInjectionYieldsNil() {
        // FocusSnapshot windows the field around the caret; here the window
        // sliced through the injection and only its tail is visible.
        let injected = (1...20).map { "unique\($0)" }.joined(separator: " ")
        let tail = (12...20).map { "unique\($0)" }.joined(separator: " ")
        let field = "some other document text sits before the cut " + tail
        XCTAssertNil(span(injected, in: field))
    }

    func testRepeatedPhraseIsAmbiguousYieldsNil() {
        // Two places tie on similarity — either could be the injection, so
        // neither is trusted.
        let injected = "call bob tomorrow"
        let field = "call bob today and later call bob sunday"
        XCTAssertNil(span(injected, in: field))
    }

    func testTrailingReplacementNextToDocumentTextStaysSafe() {
        // "noon" became "midnight" right where the document continues; the
        // match cannot tell a boundary replacement from a neighboring word,
        // so the span stops at the last anchored word rather than guess.
        let injected = "meet john at noon"
        let field = "meet john at midnight Fine details follow in the next section."
        XCTAssertEqual(span(injected, in: field), "meet john at")
    }
}
