import XCTest
@testable import Aloud

// The number thrown off the composer when the Concise rewrite shortens what the
// user said. It is a flourish, so the arithmetic is deliberately rough — but it
// must never claim a saving that did not happen, which is the only way a
// flourish like this can actually cost something.
@MainActor
final class TokenSavingTests: XCTestCase {

    func testAShorterRewriteSavesTokens() {
        let raw = "So I think what I want to do is, um, roll the migration back for now."
        let concise = "Roll the migration back."
        XCTAssertGreaterThan(RecordingIndicatorPanel.tokensSaved(from: raw, to: concise), 0)
    }

    // Nothing was rewritten. A badge here would be announcing a benefit for
    // work that was not done.
    func testAnUnchangedSentenceSavesNothing() {
        let same = "Roll the migration back."
        XCTAssertEqual(RecordingIndicatorPanel.tokensSaved(from: same, to: same), 0)
    }

    // The rewrite came out longer, which does happen. The badge must not go
    // negative, and must not appear at all — advertising a loss as a win is
    // worse than staying quiet.
    func testALongerRewriteNeverGoesNegative() {
        let saved = RecordingIndicatorPanel.tokensSaved(
            from: "back it out",
            to: "Please roll the database migration back to the previous revision.")
        XCTAssertEqual(saved, 0)
    }

    func testEmptyTextIsHarmless() {
        XCTAssertEqual(RecordingIndicatorPanel.tokensSaved(from: "", to: ""), 0)
        XCTAssertEqual(RecordingIndicatorPanel.estimatedTokens(""), 0)
    }

    // Four characters to a token, roughly — the usual rule of thumb, and enough
    // for a number nobody is going to bill against.
    func testTheEstimateIsAboutFourCharactersPerToken() {
        XCTAssertEqual(RecordingIndicatorPanel.estimatedTokens(String(repeating: "a", count: 40)), 10)
        XCTAssertEqual(RecordingIndicatorPanel.estimatedTokens(String(repeating: "a", count: 4)), 1)
    }
}
