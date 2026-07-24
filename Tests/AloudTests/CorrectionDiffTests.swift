import XCTest
@testable import Aloud

final class CorrectionDiffTests: XCTestCase {
    private func diff(_ original: String, _ corrected: String) -> [CorrectionDiff.Candidate] {
        CorrectionDiff.candidates(original: original, corrected: corrected)
    }

    private func pair(_ from: String, _ to: String) -> CorrectionDiff.Candidate {
        CorrectionDiff.Candidate(from: from, to: to)
    }

    // MARK: single-word substitutions

    func testSingleWordFix() {
        XCTAssertEqual(diff("Send it to John.", "Send it to Jon."),
                       [pair("John", "Jon")])
    }

    func testFixInMiddlePreservesSurroundings() {
        XCTAssertEqual(diff("The sequel query is slow.", "The SQL query is slow."),
                       [pair("sequel", "SQL")])
    }

    func testMultipleSeparateFixes() {
        XCTAssertEqual(diff("Ask cloud about the sequel query.",
                            "Ask Claude about the SQL query."),
                       [pair("cloud", "Claude"), pair("sequel", "SQL")])
    }

    // MARK: phrase grouping

    func testAdjacentChangesGroupIntoOnePhrase() {
        XCTAssertEqual(diff("Meet jon smith at noon.", "Meet Jon Smyth at noon."),
                       [pair("jon smith", "Jon Smyth")])
    }

    func testPhraseWithDifferentWordCounts() {
        // One spoken word heard as two (or vice versa) still pairs up whole.
        XCTAssertEqual(diff("Open the pie torch docs.", "Open the PyTorch docs."),
                       [pair("pie torch", "PyTorch")])
        XCTAssertEqual(diff("Use killer cotta for that.", "Use Kelly Carter for that."),
                       [pair("killer cotta", "Kelly Carter")])
    }

    func testChangesSeparatedByAnchorStaySeparate() {
        XCTAssertEqual(diff("jon met the smith today.", "Jon met the Smyth today."),
                       [pair("jon", "Jon"), pair("smith", "Smyth")])
    }

    // MARK: case-only changes

    func testCaseFixOfNameIsKept() {
        XCTAssertEqual(diff("Tell abe I'm coming.", "Tell Abe I'm coming."),
                       [pair("abe", "Abe")])
    }

    func testCaseChangeOfCommonWordIsNoise() {
        // Re-splitting a sentence re-capitalizes "the" — not vocabulary.
        XCTAssertEqual(diff("we went home. the end.", "We went home. The end."), [])
    }

    func testCaseChangeMergedIntoRealFixIsKept() {
        // A common word's case flip that rides along with a real change stays
        // part of the phrase.
        XCTAssertEqual(diff("call the acme team", "call The ACME Corp team"),
                       [pair("the acme", "The ACME Corp")])
    }

    // MARK: punctuation-only changes

    func testPunctuationOnlyChangesIgnored() {
        XCTAssertEqual(diff("Hello world", "Hello, world!"), [])
        XCTAssertEqual(diff("Send it Tuesday.", "Send it Tuesday"), [])
    }

    func testPunctuationAroundRealFixIsStripped() {
        // The learned pattern is the bare word, not "smith," with its comma.
        XCTAssertEqual(diff("Hi smith, welcome.", "Hi Smyth, welcome."),
                       [pair("smith", "Smyth")])
    }

    func testInteriorPunctuationKept() {
        XCTAssertEqual(diff("Check the wifi setup.", "Check the Wi-Fi setup."),
                       [pair("wifi", "Wi-Fi")])
    }

    // MARK: insertions and deletions

    func testPureInsertionIsNotACandidate() {
        XCTAssertEqual(diff("Send the report.", "Send the quarterly report."), [])
    }

    func testPureDeletionIsNotACandidate() {
        XCTAssertEqual(diff("Send the quarterly report.", "Send the report."), [])
    }

    func testInsertionAdjacentToChangeJoinsThePhrase() {
        XCTAssertEqual(diff("Email jean about it.", "Email Gene Kim about it."),
                       [pair("jean", "Gene Kim")])
    }

    // MARK: length limit

    func testLongRewriteIsNotACandidate() {
        // Five changed words in a row is a rewrite, not a term to learn.
        XCTAssertEqual(diff("one two three four five end",
                            "uno dos tres cuatro cinco end"), [])
    }

    func testFourWordPhraseIsStillACandidate() {
        XCTAssertEqual(diff("the a b c d end", "the W X Y Z end"),
                       [pair("a b c d", "W X Y Z")])
    }

    // MARK: degenerate inputs

    func testIdenticalTextsYieldNothing() {
        XCTAssertEqual(diff("Nothing changed here.", "Nothing changed here."), [])
    }

    func testEmptyInputsYieldNothing() {
        XCTAssertEqual(diff("", "Some text"), [])
        XCTAssertEqual(diff("Some text", ""), [])
        XCTAssertEqual(diff("", ""), [])
    }

    func testWhitespaceOnlyDifferencesIgnored() {
        XCTAssertEqual(diff("hello   world", "hello world"), [])
        XCTAssertEqual(diff("hello world", "hello\nworld"), [])
    }

    func testCompleteRewriteYieldsNothing() {
        XCTAssertEqual(diff("alpha beta gamma delta epsilon zeta",
                            "completely different words entirely spoken here"), [])
    }

    // MARK: duplicates

    func testRepeatedFixCollapsesToOneCandidate() {
        XCTAssertEqual(diff("sequel here and sequel there.", "SQL here and SQL there."),
                       [pair("sequel", "SQL")])
    }

    func testDuplicateDetectionIsCaseInsensitive() {
        XCTAssertEqual(diff("Sequel here and sequel there.", "SQL here and SQL there."),
                       [pair("Sequel", "SQL")])
    }
}
