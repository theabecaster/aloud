import AppKit
import XCTest
@testable import Aloud

final class TextInjectorSnapshotTests: XCTestCase {
    private func makeBoard(_ name: String) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("aloud-test-\(name)-\(getpid())"))
        board.clearContents()
        return board
    }

    // A pasteboard item lists its flavors richest-first and the pasting app
    // takes the first one it understands, so the restore must hand them back
    // in the order they were copied.
    func testRestorePreservesFlavorOrder() {
        let board = makeBoard("flavor-order")
        let item = NSPasteboardItem()
        item.setData(Data("<html>hi</html>".utf8), forType: .html)
        item.setData(Data("*hi*".utf8), forType: NSPasteboard.PasteboardType("public.utf8-plain-text"))
        item.setData(Data("hi".utf8), forType: .string)
        board.writeObjects([item])
        let original = board.pasteboardItems?.first?.types.map(\.rawValue) ?? []
        XCTAssertGreaterThan(original.count, 1, "test needs a multi-flavor item")

        let injector = TextInjector(pasteboard: board, postEvents: false)
        let snap = injector.snapshot()
        board.clearContents()
        board.setString("dictated text", forType: .string)
        injector.restore(snap)

        XCTAssertEqual(board.pasteboardItems?.first?.types.map(\.rawValue), original)
    }

    func testRestoreReturnsEveryFlavorsData() {
        let board = makeBoard("flavor-data")
        let item = NSPasteboardItem()
        item.setData(Data("<html>hi</html>".utf8), forType: .html)
        item.setData(Data("hi".utf8), forType: .string)
        board.writeObjects([item])

        let injector = TextInjector(pasteboard: board, postEvents: false)
        let snap = injector.snapshot()
        board.clearContents()
        board.setString("dictated text", forType: .string)
        injector.restore(snap)

        let restored = board.pasteboardItems?.first
        XCTAssertEqual(restored?.data(forType: .html), Data("<html>hi</html>".utf8))
        XCTAssertEqual(restored?.data(forType: .string), Data("hi".utf8))
    }

    func testRestoreKeepsItemOrderForMultipleItems() {
        let board = makeBoard("item-order")
        let first = NSPasteboardItem()
        first.setData(Data("one".utf8), forType: .string)
        let second = NSPasteboardItem()
        second.setData(Data("two".utf8), forType: .string)
        board.writeObjects([first, second])

        let injector = TextInjector(pasteboard: board, postEvents: false)
        let snap = injector.snapshot()
        board.clearContents()
        board.setString("dictated text", forType: .string)
        injector.restore(snap)

        XCTAssertEqual(board.pasteboardItems?.compactMap { $0.string(forType: .string) }, ["one", "two"])
    }
}
