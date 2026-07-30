import XCTest
@testable import Aloud

final class EditTrackerTests: XCTestCase {

    private func track(_ injected: String, _ inputs: [EditTracker.Input]) -> EditTracker {
        var tracker = EditTracker(injected: injected)
        for input in inputs { tracker.consume(input) }
        return tracker
    }

    // MARK: replaying ordinary edits

    func testUntouchedIsNotEdited() {
        let t = track("say hi to John Smith", [])
        XCTAssertEqual(t.state, .tracking)
        XCTAssertFalse(t.edited)
    }

    func testBackspaceAndRetypeAtEnd() {
        let t = track("say hi to John Smith",
                      Array(repeating: .backspace, count: 5) + [.text("Smyth")])
        XCTAssertEqual(t.text, "say hi to John Smyth")
        XCTAssertTrue(t.edited)
        XCTAssertEqual(t.state, .tracking)
    }

    func testRetypingTheSameTextIsNotAnEdit() {
        let t = track("say hi to John Smith",
                      Array(repeating: .backspace, count: 5) + [.text("Smith")])
        XCTAssertFalse(t.edited)
    }

    func testArrowIntoMiddleAndForwardDelete() {
        // "abcdef" → cursor to after "abc", forward-delete "d", type "D"
        let t = track("abcdef",
                      Array(repeating: .left, count: 3) + [.forwardDelete, .text("D")])
        XCTAssertEqual(t.text, "abcDef")
    }

    func testCharactersArriveOneKeystrokeAtATime() {
        let t = track("hi", [.text("!"), .text("!")])
        XCTAssertEqual(t.text, "hi!!")
    }

    func testShiftSelectionReplacedByTyping() {
        let t = track("John Smith",
                      Array(repeating: .shiftLeft, count: 5) + [.text("Smyth")])
        XCTAssertEqual(t.text, "John Smyth")
    }

    func testShiftSelectionDeletedByBackspace() {
        let t = track("John Smith X",
                      Array(repeating: .shiftLeft, count: 2) + [.backspace])
        XCTAssertEqual(t.text, "John Smith")
    }

    func testPlainArrowCollapsesSelectionToItsEdge() {
        // Select "th" backwards, then plain left collapses to the selection
        // start; typing inserts there rather than replacing.
        let t = track("Smith",
                      [.shiftLeft, .shiftLeft, .left, .text("y")])
        XCTAssertEqual(t.text, "Smiyth")
    }

    func testShiftBackAndForthLeavesNoSelection() {
        // Selection dragged out and back to its anchor is no selection at
        // all — the next backspace must delete one character, not a phantom
        // selected range.
        let t = track("abc", [.shiftLeft, .shiftRight, .backspace])
        XCTAssertEqual(t.text, "ab")
    }

    func testGraphemeClusterDeletesAsOne() {
        let t = track("hi 👨‍👩‍👧‍👦", [.backspace])
        XCTAssertEqual(t.text, "hi ")
    }

    // MARK: freezing on anything unreplayable

    func testClickFreezesButKeepsEditsSoFar() {
        var t = track("John Smith",
                      Array(repeating: .backspace, count: 5) + [.text("Smyth")])
        XCTAssertEqual(t.consume(.other), .frozen)
        XCTAssertEqual(t.text, "John Smyth")
        XCTAssertTrue(t.edited)
    }

    func testFrozenModelIgnoresFurtherInput() {
        var t = track("abc", [.other])
        t.consume(.backspace)
        t.consume(.text("x"))
        XCTAssertEqual(t.text, "abc")
        XCTAssertFalse(t.edited)
    }

    func testLeavingTheSpanFreezes() {
        // Off the left edge…
        var t = track("ab", [.left, .left])
        XCTAssertEqual(t.consume(.left), .frozen)
        // …off the right edge…
        t = track("ab", [])
        XCTAssertEqual(t.consume(.right), .frozen)
        // …backspacing into text before the injection…
        t = track("ab", [.left, .left])
        XCTAssertEqual(t.consume(.backspace), .frozen)
        // …and forward-deleting into text after it.
        t = track("ab", [])
        XCTAssertEqual(t.consume(.forwardDelete), .frozen)
    }

    func testShiftSelectionPastEdgesFreezes() {
        var t = track("a", [.shiftLeft])
        XCTAssertEqual(t.consume(.shiftLeft), .frozen)
        t = track("a", [])
        XCTAssertEqual(t.consume(.shiftRight), .frozen)
    }

    func testEmptyOrControlKeystrokeFreezes() {
        // A dead key mid-compose or a function key delivers no insertable
        // text; the field state is no longer knowable.
        var t = track("abc", [])
        XCTAssertEqual(t.consume(.text("")), .frozen)
        t = track("abc", [])
        XCTAssertEqual(t.consume(.text("\u{F700}")), .frozen)
    }

    func testEditsBeforeAFreezeStillCount() {
        // Fix the name, then click elsewhere: the fix is real and kept.
        var t = track("say hi to John Smith",
                      Array(repeating: .backspace, count: 5) + [.text("Smyth")])
        t.consume(.other)
        XCTAssertEqual(t.text, "say hi to John Smyth")
        XCTAssertTrue(t.edited)
    }

    // MARK: realistic correction shapes

    func testFixingAWordInTheMiddle() {
        // "meet at the cafe tomorrow" → select "cafe" backwards from just
        // after it and retype.
        let t = track("meet at the cafe tomorrow",
                      Array(repeating: .left, count: 9)      // cursor after "cafe"
                      + Array(repeating: .shiftLeft, count: 4)
                      + [.text("café")])
        XCTAssertEqual(t.text, "meet at the café tomorrow")
    }

    func testAppendingMoreTextIsAnEditButPureInsertion() {
        // The tracker reports it; downstream diffing decides no vocabulary
        // pair comes out of a pure insertion.
        let t = track("hello", [.text(" there")])
        XCTAssertEqual(t.text, "hello there")
        XCTAssertTrue(t.edited)
    }
}
