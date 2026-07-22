import XCTest
@testable import Aloud

final class HotkeyEngineTests: XCTestCase {
    func testModifierHoldCommit() {
        var engine = HotkeyEngine(hotkey: .default)
        let flag = Hotkey.default.modifierFlag!
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: 54, flags: flag, time: 0), .begin)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: 54, flags: [], time: 1.0), .commit)
    }

    func testShortTapCancels() {
        var engine = HotkeyEngine(hotkey: .default)
        let flag = Hotkey.default.modifierFlag!
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: 54, flags: flag, time: 0), .begin)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: 54, flags: [], time: 0.05), .cancel)
    }

    func testEscCancelsWhileHeld() {
        var engine = HotkeyEngine(hotkey: .default)
        let flag = Hotkey.default.modifierFlag!
        _ = engine.handle(type: .flagsChanged, keyCode: 54, flags: flag, time: 0)
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 53, flags: flag, time: 0.3), .cancel)
        // A later release must not double-fire.
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: 54, flags: [], time: 0.5), .none)
    }

    func testOtherModifierIgnored() {
        var engine = HotkeyEngine(hotkey: .default)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: 58, flags: .maskAlternate, time: 0), .none)
    }

    func testRegularKeyHotkey() {
        var engine = HotkeyEngine(hotkey: Hotkey(keyCode: 96, modifiers: 0, isModifierKey: false))
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 96, flags: [], time: 0), .begin)
        XCTAssertEqual(engine.handle(type: .keyUp, keyCode: 96, flags: [], time: 0.5), .commit)
    }

    func testHotkeyCodableRoundTrip() throws {
        let hk = Hotkey(keyCode: 96, modifiers: CGEventFlags.maskCommand.rawValue, isModifierKey: false)
        let decoded = try JSONDecoder().decode(Hotkey.self, from: JSONEncoder().encode(hk))
        XCTAssertEqual(decoded, hk)
    }
}

final class UpdaterTests: XCTestCase {
    func testSemver() {
        XCTAssertTrue(Updater.semverLess("1.0.0", "1.0.1"))
        XCTAssertTrue(Updater.semverLess("v1.9.0", "v1.10.0"))
        XCTAssertFalse(Updater.semverLess("2.0.0", "1.9.9"))
        XCTAssertFalse(Updater.semverLess("1.2.3", "1.2.3"))
        XCTAssertTrue(Updater.semverLess("1.2", "1.2.1"))
    }
}

final class HistoryStoreTests: XCTestCase {
    func testAppendLimitAndPersistence() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.json")

        let store = HistoryStore(fileURL: url)
        for i in 0..<8 { store.append(HistoryEntry(text: "entry \(i)", duration: 0.5), limit: 5) }
        XCTAssertEqual(store.entries.count, 5)
        XCTAssertEqual(store.entries.first?.text, "entry 7")

        // async persist
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 0.2)
        let reloaded = HistoryStore(fileURL: url)
        XCTAssertEqual(reloaded.entries.count, 5)
    }
}

final class SettingsStoreTests: XCTestCase {
    func testRoundTrip() {
        let suite = "aloud-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let s1 = SettingsStore(defaults: defaults)
        XCTAssertEqual(s1.hotkey, .default)
        let custom = Hotkey(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue, isModifierKey: false)
        s1.hotkey = custom
        s1.launchAtLogin = true
        s1.microphoneUID = "some-uid"
        s1.historyLimit = 10

        let s2 = SettingsStore(defaults: defaults)
        XCTAssertEqual(s2.hotkey, custom)
        XCTAssertTrue(s2.launchAtLogin)
        XCTAssertEqual(s2.microphoneUID, "some-uid")
        XCTAssertEqual(s2.historyLimit, 10)
    }
}

final class HotkeyDisplayTests: XCTestCase {
    func testDisplayNames() {
        XCTAssertEqual(Hotkey.default.displayName, "⌘ (right)")
        let withMods = Hotkey(keyCode: 49, modifiers: CGEventFlags.maskCommand.rawValue, isModifierKey: false)
        XCTAssertEqual(withMods.displayName, "⌘Space")
    }
}
