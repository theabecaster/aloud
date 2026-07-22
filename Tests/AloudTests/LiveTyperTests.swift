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

    func testFreezeStopsEdits() {
        let typer = LiveTyper(postEvents: false)
        typer.apply("first words")
        typer.freeze()
        typer.apply("first words revised")
        XCTAssertEqual(typer.typed, "first words")
        typer.eraseAll()
        XCTAssertEqual(typer.typed, "first words")   // frozen: nothing is deleted
        typer.reset()
        XCTAssertEqual(typer.typed, "")
        XCTAssertFalse(typer.isFrozen)
    }
}
