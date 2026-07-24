import XCTest
@testable import Aloud

final class ScratchpadStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-scratchpad-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("scratchpad.txt")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    // Saves are async — poll until the file holds what we expect (or time out).
    private func waitForFileContents(_ expected: String) -> Bool {
        for _ in 0..<100 {
            if (try? String(contentsOf: fileURL, encoding: .utf8)) == expected { return true }
            usleep(20_000)
        }
        return false
    }

    func testTextSurvivesRelaunch() {
        let store = ScratchpadStore(fileURL: fileURL)
        XCTAssertEqual(store.text, "")
        store.text = "milk, eggs\ncall the bank"
        XCTAssertTrue(waitForFileContents("milk, eggs\ncall the bank"))
        // A fresh store (a relaunch) picks the note back up.
        XCTAssertEqual(ScratchpadStore(fileURL: fileURL).text, "milk, eggs\ncall the bank")
    }

    func testClearingPersistsEmpty() {
        let store = ScratchpadStore(fileURL: fileURL)
        store.text = "temporary thought"
        XCTAssertTrue(waitForFileContents("temporary thought"))
        store.text = ""
        XCTAssertTrue(waitForFileContents(""))
    }

    func testMissingFileMeansEmptyNote() {
        XCTAssertEqual(ScratchpadStore(fileURL: fileURL).text, "")
    }
}
