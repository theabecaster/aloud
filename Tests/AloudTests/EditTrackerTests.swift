import XCTest
@testable import Aloud

final class EditTrackerTests: XCTestCase {

    private func track(_ injected: String, _ inputs: [EditTracker.Input]) -> EditTracker {
        var tracker = EditTracker(injected: injected)
        for input in inputs { tracker.consume(input) }
        return tracker
    }

    // MARK: exact phase — replaying ordinary edits

    func testUntouchedIsNotEdited() {
        let t = track("say hi to John Smith", [])
        XCTAssertEqual(t.phase, .exact)
        XCTAssertFalse(t.outcome.exactEdited)
        XCTAssertTrue(t.outcome.bursts.isEmpty)
    }

    func testBackspaceAndRetypeAtEnd() {
        let t = track("say hi to John Smith",
                      Array(repeating: .backspace, count: 5) + [.text("Smyth")])
        XCTAssertEqual(t.outcome.exactText, "say hi to John Smyth")
        XCTAssertTrue(t.outcome.exactEdited)
        XCTAssertEqual(t.phase, .exact)
    }

    func testRetypingTheSameTextIsNotAnEdit() {
        let t = track("say hi to John Smith",
                      Array(repeating: .backspace, count: 5) + [.text("Smith")])
        XCTAssertFalse(t.outcome.exactEdited)
    }

    func testArrowIntoMiddleAndForwardDelete() {
        let t = track("abcdef",
                      Array(repeating: .left, count: 3) + [.forwardDelete, .text("D")])
        XCTAssertEqual(t.outcome.exactText, "abcDef")
    }

    func testShiftSelectionReplacedByTyping() {
        let t = track("John Smith",
                      Array(repeating: .shiftLeft, count: 5) + [.text("Smyth")])
        XCTAssertEqual(t.outcome.exactText, "John Smyth")
    }

    func testShiftSelectionDeletedByBackspace() {
        let t = track("John Smith X",
                      Array(repeating: .shiftLeft, count: 2) + [.backspace])
        XCTAssertEqual(t.outcome.exactText, "John Smith")
    }

    func testPlainArrowCollapsesSelectionToItsEdge() {
        let t = track("Smith",
                      [.shiftLeft, .shiftLeft, .left, .text("y")])
        XCTAssertEqual(t.outcome.exactText, "Smiyth")
    }

    func testShiftBackAndForthLeavesNoSelection() {
        let t = track("abc", [.shiftLeft, .shiftRight, .backspace])
        XCTAssertEqual(t.outcome.exactText, "ab")
    }

    func testGraphemeClusterDeletesAsOne() {
        let t = track("hi 👨‍👩‍👧‍👦", [.backspace])
        XCTAssertEqual(t.outcome.exactText, "hi ")
    }

    func testFixingAWordInTheMiddle() {
        let t = track("meet at the cafe tomorrow",
                      Array(repeating: .left, count: 9)
                      + Array(repeating: .shiftLeft, count: 4)
                      + [.text("café")])
        XCTAssertEqual(t.outcome.exactText, "meet at the café tomorrow")
    }

    // MARK: demoting to approximate instead of giving up

    func testClickDemotesAndKeepsExactEditsSoFar() {
        let t = track("John Smith",
                      Array(repeating: .backspace, count: 5) + [.text("Smyth"), .click])
        XCTAssertEqual(t.phase, .approximate)
        XCTAssertEqual(t.outcome.exactText, "John Smyth")
        XCTAssertTrue(t.outcome.exactEdited)
    }

    func testTypingAfterAClickBecomesABurst() {
        let t = track("say hi to John Smith", [.click, .text("S"), .text("myth")])
        XCTAssertEqual(t.outcome.bursts, ["Smyth"])
        XCTAssertFalse(t.outcome.exactEdited)
    }

    func testBackspaceInsideABurstEditsTheBurst() {
        let t = track("John Smith", [.click, .text("Smytj"), .backspace, .text("h")])
        XCTAssertEqual(t.outcome.bursts, ["Smyth"])
    }

    func testBackspacePastTheBurstIsHarmless() {
        // Deleting selection remnants before typing: the burst is content,
        // not position, so unknown deletions cost nothing.
        let t = track("John Smith", [.click, .backspace, .backspace, .text("Smyth")])
        XCTAssertEqual(t.outcome.bursts, ["Smyth"])
    }

    func testCursorJumpsSeparateBursts() {
        let t = track("meet Jon at the cafe",
                      [.click, .text("John"), .click, .text("café")])
        XCTAssertEqual(t.outcome.bursts, ["John", "café"])
    }

    func testArrowsActAsBurstSeparatorsWhenApproximate() {
        let t = track("abc def", [.nav, .text("one"), .left, .text("two")])
        XCTAssertEqual(t.outcome.bursts, ["one", "two"])
    }

    func testLeavingTheSpanDemotesRatherThanEnds() {
        var t = track("ab", [.left, .left])
        XCTAssertEqual(t.consume(.left), .approximate)
        t = track("ab", [])
        XCTAssertEqual(t.consume(.right), .approximate)
        t = track("ab", [.left, .left])
        XCTAssertEqual(t.consume(.backspace), .approximate)
        t = track("ab", [])
        XCTAssertEqual(t.consume(.forwardDelete), .approximate)
    }

    // MARK: ending outright on the unknowable

    func testChordEndsTrackingAndKeepsEverything() {
        var t = track("John Smith",
                      Array(repeating: .backspace, count: 5)
                      + [.text("Smyth"), .click, .text("café")])
        XCTAssertEqual(t.consume(.other), .done)
        XCTAssertEqual(t.outcome.exactText, "John Smyth")
        XCTAssertEqual(t.outcome.bursts, ["café"])
        t.consume(.text("ignored"))
        XCTAssertEqual(t.outcome.bursts, ["café"])
    }

    func testDeadKeyEndsTrackingInEitherPhase() {
        var t = track("abc", [])
        XCTAssertEqual(t.consume(.text("")), .done)
        t = track("abc", [.click])
        XCTAssertEqual(t.consume(.text("\u{F700}")), .done)
    }

    func testBurstCapEndsTracking() {
        var inputs: [EditTracker.Input] = [.click]
        for i in 0..<EditTracker.maxBursts {
            inputs += [.text("word\(i)"), .click]
        }
        let t = track("some dictated text", inputs)
        XCTAssertEqual(t.phase, .done)
        XCTAssertEqual(t.outcome.bursts.count, EditTracker.maxBursts)
    }

    func testAppendingMoreTextIsAnEditButPureInsertion() {
        let t = track("hello", [.text(" there")])
        XCTAssertEqual(t.outcome.exactText, "hello there")
        XCTAssertTrue(t.outcome.exactEdited)
    }
}

final class CorrectionGuessTests: XCTestCase {

    func testUniqueNearMatchIsTheReplacedWord() {
        let c = CorrectionGuess.candidate(injected: "say hi to John Smith for me", typed: "Smyth")
        XCTAssertEqual(c, CorrectionDiff.Candidate(from: "Smith", to: "Smyth"))
    }

    func testUnrelatedTypingMatchesNothing() {
        XCTAssertNil(CorrectionGuess.candidate(injected: "say hi to John Smith", typed: "banana"))
    }

    func testRetypingAnExistingWordIsNoCorrection() {
        XCTAssertNil(CorrectionGuess.candidate(injected: "say hi to John Smith", typed: "Smith"))
        // Case-only difference is sentence position, not vocabulary.
        XCTAssertNil(CorrectionGuess.candidate(injected: "say hi to John Smith", typed: "smith"))
    }

    func testTwoEquallyCloseHomesMeansNoGuess() {
        XCTAssertNil(CorrectionGuess.candidate(injected: "the bat saw the cat", typed: "rat"))
    }

    func testCloserHomeWinsOverFartherOne() {
        // Both surnames are within tolerance for their length; the closer
        // one is the only sensible home.
        let c = CorrectionGuess.candidate(injected: "ask Gonzalez or Gonzalvo", typed: "Gonzales")
        XCTAssertEqual(c?.from, "Gonzalez")
    }

    func testMultiWordPhraseMatches() {
        let c = CorrectionGuess.candidate(injected: "email Jon Smith about the deck", typed: "John Smyth")
        XCTAssertEqual(c, CorrectionDiff.Candidate(from: "Jon Smith", to: "John Smyth"))
    }

    func testTinyBurstsNeverMatch() {
        XCTAssertNil(CorrectionGuess.candidate(injected: "say hi to it", typed: "at"))
    }

    func testDistanceScalesWithLengthNotGenerosity() {
        // "the" → "there" is 2 edits on a 3-letter word: new writing, not a fix.
        XCTAssertNil(CorrectionGuess.candidate(injected: "put the box down", typed: "there"))
    }

    func testLongBurstsAreNewWritingNotFixes() {
        let essay = String(repeating: "reconsidering ", count: 6)
        XCTAssertNil(CorrectionGuess.candidate(injected: "a short note", typed: essay))
    }

    func testPunctuationAroundTheBurstIsIgnored() {
        let c = CorrectionGuess.candidate(injected: "call Marc tomorrow", typed: "Mark,")
        XCTAssertEqual(c, CorrectionDiff.Candidate(from: "Marc", to: "Mark"))
    }

    func testRepeatedWordStillMatchesWhenBothHomesAgree() {
        // Two homes with the same surface are one answer, not an ambiguity.
        let c = CorrectionGuess.candidate(injected: "Smith called Smith back", typed: "Smyth")
        XCTAssertEqual(c?.from, "Smith")
    }
}

final class EditDistanceTests: XCTestCase {

    func testEmptySidesDoNotTrapTheTable() {
        // A zero-length side used to walk a zero-width row and trap. Reachable
        // through the booster's plausibility gate, whose terms come from user
        // data that can hold anything.
        XCTAssertEqual(CorrectionGuess.editDistance("", "", limit: 0), 0)
        XCTAssertEqual(CorrectionGuess.editDistance("ab", "", limit: 2), 2)
        XCTAssertEqual(CorrectionGuess.editDistance("", "ab", limit: 2), 2)
        XCTAssertNil(CorrectionGuess.editDistance("abc", "", limit: 2))
    }

    func testDistanceAndCutoff() {
        XCTAssertEqual(CorrectionGuess.editDistance("smith", "smyth", limit: 2), 1)
        XCTAssertEqual(CorrectionGuess.editDistance("same", "same", limit: 0), 0)
        XCTAssertNil(CorrectionGuess.editDistance("kitten", "sitting", limit: 2),
                     "three edits, cut off at two")
        XCTAssertEqual(CorrectionGuess.editDistance("kitten", "sitting", limit: 3), 3)
    }
}
