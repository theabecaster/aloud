import XCTest
@testable import Aloud

final class TypedTextDiffTests: XCTestCase {
    func testAppendOnly() {
        let d = TypedTextDiff.from("hello", to: "hello world")
        XCTAssertEqual(d.backspaces, 0)
        XCTAssertEqual(d.insertion, " world")
    }

    func testRevisionMidText() {
        let d = TypedTextDiff.from("I went their", to: "I went there today")
        XCTAssertEqual(d.backspaces, 2)
        XCTAssertEqual(d.insertion, "re today")
    }

    func testFullReplace() {
        let d = TypedTextDiff.from("abc", to: "xyz")
        XCTAssertEqual(d.backspaces, 3)
        XCTAssertEqual(d.insertion, "xyz")
    }

    func testNoChange() {
        let d = TypedTextDiff.from("same", to: "same")
        XCTAssertEqual(d.backspaces, 0)
        XCTAssertEqual(d.insertion, "")
    }

    func testEraseAll() {
        let d = TypedTextDiff.from("goodbye", to: "")
        XCTAssertEqual(d.backspaces, 7)
        XCTAssertEqual(d.insertion, "")
    }

    func testFromEmpty() {
        let d = TypedTextDiff.from("", to: "hi")
        XCTAssertEqual(d.backspaces, 0)
        XCTAssertEqual(d.insertion, "hi")
    }

    // Backspaces count grapheme clusters, not UTF-16 units — one Delete press
    // removes a whole emoji.
    func testGraphemeClusters() {
        let d = TypedTextDiff.from("ok 👍🏽", to: "ok 🎉")
        XCTAssertEqual(d.backspaces, 1)
        XCTAssertEqual(d.insertion, "🎉")
    }

    func testShorterTarget() {
        let d = TypedTextDiff.from("hello world", to: "hello")
        XCTAssertEqual(d.backspaces, 6)
        XCTAssertEqual(d.insertion, "")
    }
}

final class LiveTyperTests: XCTestCase {
    func testTracksTypedTextHeadless() {
        let typer = LiveTyper(postEvents: false)
        typer.apply("hello")
        typer.apply("hello world")
        typer.apply("hello there")
        XCTAssertEqual(typer.typed, "hello there")
        typer.eraseAll()
        XCTAssertEqual(typer.typed, "")
    }

    // A rebase surrenders the text typed so far and keeps dictation flowing:
    // later applies sync only the transcript tail at the new cursor position.
    func testRebaseContinuesWithTailOnly() {
        let typer = LiveTyper(postEvents: false)
        typer.apply("first words")
        typer.rebase()
        XCTAssertEqual(typer.typed, "")
        typer.apply("first words and more")
        XCTAssertEqual(typer.typed, " and more")
        typer.apply("first words and more still")
        XCTAssertEqual(typer.typed, " and more still")
    }

    // Erasing after a rebase removes only the post-rebase tail — the
    // surrendered text is out of reach and must not be touched.
    func testEraseAfterRebaseKeepsSurrenderedText() {
        let typer = LiveTyper(postEvents: false)
        typer.apply("keep this")
        typer.rebase()
        typer.apply("keep this but not this")
        typer.eraseAll()
        XCTAssertEqual(typer.typed, "")
        XCTAssertEqual(typer.anchorCount, "keep this".count)
    }

    // Rebases accumulate: each one moves the anchor past whatever was typed
    // since the previous rebase.
    func testRepeatedRebase() {
        let typer = LiveTyper(postEvents: false)
        typer.apply("one")
        typer.rebase()
        typer.rebase()   // user kept typing; nothing new applied in between
        typer.apply("one two")
        XCTAssertEqual(typer.typed, " two")
        typer.rebase()
        typer.apply("one two three")
        XCTAssertEqual(typer.typed, " three")
        typer.reset()
        XCTAssertEqual(typer.typed, "")
        XCTAssertEqual(typer.anchorCount, 0)
    }

    // A revised transcript shorter than the anchor must not crash or type.
    func testTargetShorterThanAnchor() {
        let typer = LiveTyper(postEvents: false)
        typer.apply("hello world")
        typer.rebase()
        typer.apply("hello")
        XCTAssertEqual(typer.typed, "")
    }
}
