import XCTest
@testable import Aloud

final class TextPolisherTests: XCTestCase {
    private func polish(_ s: String, level: PolishLevel = .standard,
                        replacements: [Replacement] = []) -> String {
        TextPolisher(level: level, replacements: replacements).polish(s)
    }

    // MARK: off

    func testOffIsUntouched() {
        XCTAssertEqual(polish("um, so like  this .", level: .off), "um, so like  this .")
    }

    // MARK: fillers

    func testFillerRemoval() {
        XCTAssertEqual(polish("Um, I think, uh, we should go."), "I think, we should go.")
        XCTAssertEqual(polish("So, um, yes."), "So, yes.")
        XCTAssertEqual(polish("Hmm. That works."), "That works.")
    }

    func testFillerInsideWordsUntouched() {
        XCTAssertEqual(polish("The umbrella and the summit."), "The umbrella and the summit.")
        // "like"/"you know" carry meaning — never removed.
        XCTAssertEqual(polish("I like this, you know it."), "I like this, you know it.")
    }

    // MARK: self-corrections

    func testScratchThat() {
        XCTAssertEqual(polish("Send it Tuesday, scratch that, send it Friday."),
                       "Send it Friday.")
        XCTAssertEqual(polish("We met at noon. Order pizza, no wait, order sushi."),
                       "We met at noon. Order sushi.")
    }

    func testScratchThatOnlyInStandard() {
        XCTAssertEqual(polish("A, scratch that, B.", level: .light), "A, scratch that, B.")
    }

    // MARK: replacements

    func testReplacements() {
        let reps = [Replacement(pattern: "cloud code", replacement: "Claude Code")]
        XCTAssertEqual(polish("I opened cloud code today.", replacements: reps),
                       "I opened Claude Code today.")
        // whole-word only
        XCTAssertEqual(polish("Cloudy codebase.", replacements: [
            Replacement(pattern: "cloud", replacement: "Claude")]), "Cloudy codebase.")
    }

    // MARK: tidy

    func testTidySpacingAndCapitalization() {
        XCTAssertEqual(polish("hello  world . next one"), "Hello world. Next one")
        XCTAssertEqual(polish(", leading comma gone"), "Leading comma gone")
    }

    func testDecimalNumbersNotCapitalized() {
        XCTAssertEqual(polish("it costs $427.62 total"), "It costs $427.62 total")
    }

    func testEmptyAndWhitespace() {
        XCTAssertEqual(polish(""), "")
        XCTAssertEqual(polish("   "), "")
        // A transcript that is nothing but fillers collapses to empty (nothing injected).
        XCTAssertEqual(polish("um, uh."), "")
    }
}

final class HandsFreeLockTests: XCTestCase {
    func testDoubleTapLocksThenTapCommits() {
        var e = HotkeyEngine(hotkey: .default)
        let flag = Hotkey.default.modifierFlag!
        // tap 1 (short)
        XCTAssertEqual(e.handle(type: .flagsChanged, keyCode: 54, flags: flag, time: 0), .begin)
        XCTAssertEqual(e.handle(type: .flagsChanged, keyCode: 54, flags: [], time: 0.05), .cancel)
        // tap 2 (short, inside window) → lock
        XCTAssertEqual(e.handle(type: .flagsChanged, keyCode: 54, flags: flag, time: 0.2), .begin)
        XCTAssertEqual(e.handle(type: .flagsChanged, keyCode: 54, flags: [], time: 0.25), .lock)
        XCTAssertTrue(e.isLocked)
        // next tap of any length → commit
        XCTAssertEqual(e.handle(type: .flagsChanged, keyCode: 54, flags: flag, time: 3.0), .none)
        XCTAssertEqual(e.handle(type: .flagsChanged, keyCode: 54, flags: [], time: 3.05), .commit)
        XCTAssertFalse(e.isLocked)
    }

    func testSlowTapsDoNotLock() {
        var e = HotkeyEngine(hotkey: .default)
        let flag = Hotkey.default.modifierFlag!
        _ = e.handle(type: .flagsChanged, keyCode: 54, flags: flag, time: 0)
        XCTAssertEqual(e.handle(type: .flagsChanged, keyCode: 54, flags: [], time: 0.05), .cancel)
        _ = e.handle(type: .flagsChanged, keyCode: 54, flags: flag, time: 1.0)   // outside window
        XCTAssertEqual(e.handle(type: .flagsChanged, keyCode: 54, flags: [], time: 1.05), .cancel)
        XCTAssertFalse(e.isLocked)
    }

    func testEscCancelsLock() {
        var e = HotkeyEngine(hotkey: .default)
        let flag = Hotkey.default.modifierFlag!
        _ = e.handle(type: .flagsChanged, keyCode: 54, flags: flag, time: 0)
        _ = e.handle(type: .flagsChanged, keyCode: 54, flags: [], time: 0.05)
        _ = e.handle(type: .flagsChanged, keyCode: 54, flags: flag, time: 0.2)
        _ = e.handle(type: .flagsChanged, keyCode: 54, flags: [], time: 0.25)
        XCTAssertTrue(e.isLocked)
        XCTAssertEqual(e.handle(type: .keyDown, keyCode: 53, flags: [], time: 1.0), .cancel)
        XCTAssertFalse(e.isLocked)
    }

    func testNormalHoldStillWorks() {
        var e = HotkeyEngine(hotkey: .default)
        let flag = Hotkey.default.modifierFlag!
        XCTAssertEqual(e.handle(type: .flagsChanged, keyCode: 54, flags: flag, time: 0), .begin)
        XCTAssertEqual(e.handle(type: .flagsChanged, keyCode: 54, flags: [], time: 2.0), .commit)
        XCTAssertFalse(e.isLocked)
    }
}
