import XCTest
@testable import Aloud

final class FocusContextTests: XCTestCase {
    // Short fields must come through byte-for-byte — windowing is only for
    // documents bigger than the cap.
    func testShortTextUntouched() {
        XCTAssertEqual(FocusSnapshot.windowed("hello", around: 2, cap: 100), "hello")
        XCTAssertEqual(FocusSnapshot.windowed("", around: nil, cap: 100), "")
    }

    func testExactlyCapUntouched() {
        let text = String(repeating: "a", count: 100)
        XCTAssertEqual(FocusSnapshot.windowed(text, around: 50, cap: 100), text)
    }

    func testWindowCenteredOnInsertionPoint() {
        // 0-9 repeated: the window must surround the pivot, half on each side.
        let text = (0..<100).map { String($0 % 10) }.joined()
        let window = FocusSnapshot.windowed(text, around: 50, cap: 10)
        XCTAssertEqual(window.count, 10)
        XCTAssertEqual(window, String(Array(text)[45..<55]))
    }

    func testWindowClampsAtStart() {
        let text = (0..<100).map { String($0 % 10) }.joined()
        let window = FocusSnapshot.windowed(text, around: 0, cap: 10)
        XCTAssertEqual(window, String(Array(text)[0..<10]))
    }

    func testWindowClampsAtEnd() {
        let text = (0..<100).map { String($0 % 10) }.joined()
        let window = FocusSnapshot.windowed(text, around: 100, cap: 10)
        XCTAssertEqual(window, String(Array(text)[90..<100]))
    }

    // No reported caret = assume appending at the end, so keep the tail.
    func testNilLocationKeepsTail() {
        let text = (0..<100).map { String($0 % 10) }.joined()
        let window = FocusSnapshot.windowed(text, around: nil, cap: 10)
        XCTAssertEqual(window, String(Array(text)[90..<100]))
    }

    // AX can hand back a range past the end of the value it also handed back
    // (attributes are read at slightly different moments) — clamp, don't trap.
    func testOutOfBoundsLocationClamped() {
        let text = String(repeating: "a", count: 50)
        XCTAssertEqual(FocusSnapshot.windowed(text, around: 9999, cap: 10).count, 10)
        XCTAssertEqual(FocusSnapshot.windowed(text, around: -5, cap: 10).count, 10)
    }

    func testDefaultCapIs2000() {
        let text = String(repeating: "a", count: 5000)
        XCTAssertEqual(FocusSnapshot.windowed(text, around: nil).count, 2000)
    }
}
