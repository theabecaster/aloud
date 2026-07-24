import XCTest
import Carbon.HIToolbox
@testable import Aloud

final class HotkeyNameTests: XCTestCase {
    // Regression: a saved hotkey on a plain letter key (e.g. X, keyCode 7) crashed
    // keyName(for:) via an invalid F-key range pattern, killing the menu on open.
    func testKeyNameNeverTrapsForAnyKeyCode() {
        for code in UInt16(0)...UInt16(255) {
            XCTAssertFalse(Hotkey.keyName(for: code).isEmpty)
        }
    }

    func testKnownKeyNames() {
        XCTAssertEqual(Hotkey.keyName(for: UInt16(kVK_F1)), "F1")
        XCTAssertEqual(Hotkey.keyName(for: UInt16(kVK_F20)), "F20")
        XCTAssertEqual(Hotkey.keyName(for: UInt16(kVK_RightOption)), "Right ⌥")
        XCTAssertEqual(Hotkey.keyName(for: UInt16(kVK_ANSI_X)), "X")
        XCTAssertFalse(Hotkey(keyCode: UInt16(kVK_ANSI_X), modifiers: 0, isModifierKey: false).displayName.isEmpty)
    }
}

final class HotkeyEngineTests: XCTestCase {
    private let key = Hotkey.default.keyCode
    private let flag = Hotkey.default.modifierFlag!

    func testModifierHoldCommit() {
        var engine = HotkeyEngine(hotkey: .default)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0), .begin)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 1.0), .commit)
    }

    func testShortTapCancels() {
        var engine = HotkeyEngine(hotkey: .default)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0), .begin)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.05), .cancel)
    }

    func testEscCancelsWhileHeld() {
        var engine = HotkeyEngine(hotkey: .default)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0)
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 53, flags: flag, time: 0.3), .cancel)
        // A later release must not double-fire.
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.5), .none)
    }

    func testOtherModifierIgnored() {
        var engine = HotkeyEngine(hotkey: .default)
        // Right ⌥ (61) toggles the same flag as the default left ⌥ but is a different key.
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: 61, flags: .maskAlternate, time: 0), .none)
    }

    func testResetClearsLockAndAllowsFreshHold() {
        var engine = HotkeyEngine(hotkey: .default)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.05)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0.2)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.25), .lock)
        engine.reset()
        XCTAssertFalse(engine.isLocked)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 1.0), .begin)
    }

    func testDoublePressLocksUntilEsc() {
        var engine = HotkeyEngine(hotkey: .default)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.05), .cancel)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0.2)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.25), .lock)
        // Hotkey presses of any length are ignored while locked.
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 1.0)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 1.8), .none)
        // Esc finishes and commits the hands-free session.
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 53, flags: [], time: 2.0), .commit)
        XCTAssertFalse(engine.isLocked)
    }

    func testDoubleTapStopsHandsFree() {
        var engine = HotkeyEngine(hotkey: .default)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.05)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0.2)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.25), .lock)
        // Double-tapping the hotkey again finishes and commits the session.
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 1.0), .none)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 1.05), .none)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 1.2), .commit)
        XCTAssertFalse(engine.isLocked)
        // The stopping tap's release is swallowed — no cancel, no new session.
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 1.25), .none)
        // A fresh press afterwards starts a normal hold, not hands-free.
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 2.0), .begin)
        XCTAssertFalse(engine.isLocked)
    }

    func testSlowTapsDoNotLock() {
        var engine = HotkeyEngine(hotkey: .default)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.05), .cancel)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 1.0)   // outside window
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 1.05), .cancel)
        XCTAssertFalse(engine.isLocked)
    }

    func testSlowTapsWhileLockedStayLocked() {
        var engine = HotkeyEngine(hotkey: .default)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.05)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0.2)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.25), .lock)
        // Presses further apart than the double-tap window do nothing.
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 1.0)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 1.05)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 2.0), .none)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 2.05), .none)
        XCTAssertTrue(engine.isLocked)
        // Esc still works as before.
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 53, flags: [], time: 3.0), .commit)
    }

    func testHandsFreeDisabled() {
        var engine = HotkeyEngine(hotkey: .default, handsFreeEnabled: false)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.05)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0.2)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.25), .cancel)
        XCTAssertFalse(engine.isLocked)
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

    func testHotkeyDecodesLegacyPayloadWithoutMouseField() throws {
        // Persisted before isMouseButton existed — must decode, not reset to default.
        let legacy = Data(#"{"keyCode":58,"modifiers":0,"isModifierKey":true}"#.utf8)
        let decoded = try JSONDecoder().decode(Hotkey.self, from: legacy)
        XCTAssertEqual(decoded, .default)
        XCTAssertFalse(decoded.isMouseButton)
    }

    func testMouseButtonHotkeyHoldCommit() {
        var engine = HotkeyEngine(hotkey: Hotkey(keyCode: 3, modifiers: 0,
                                                 isModifierKey: false, isMouseButton: true))
        XCTAssertEqual(engine.handle(type: .otherMouseDown, keyCode: 3, flags: [], time: 0), .begin)
        XCTAssertEqual(engine.handle(type: .otherMouseUp, keyCode: 3, flags: [], time: 0.5), .commit)
        // A keyboard key with the same code must not trigger a mouse hotkey.
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 3, flags: [], time: 1.0), .none)
    }

    func testMouseButtonIgnoredForKeyboardHotkey() {
        var engine = HotkeyEngine(hotkey: Hotkey(keyCode: 3, modifiers: 0, isModifierKey: false))
        XCTAssertEqual(engine.handle(type: .otherMouseDown, keyCode: 3, flags: [], time: 0), .none)
    }

    func testEnhancerOutputValidation() {
        let original = "We should move the launch back a week because testing is not done."
        // Good rewrite passes through trimmed.
        XCTAssertEqual(EnhancerOutputCheck.validate("  Move the launch back a week.  ", original: original),
                       "Move the launch back a week.")
        // The observed failure modes are all rejected.
        XCTAssertNil(EnhancerOutputCheck.validate("", original: original))
        XCTAssertNil(EnhancerOutputCheck.validate("```swift\nfunc x() {}\n```", original: original))
        XCTAssertNil(EnhancerOutputCheck.validate(String(repeating: "padding ", count: 60), original: original))
    }

    func testConciseFallsBackToStandardRules() {
        XCTAssertEqual(PolishLevel.concise.deterministicLevel, .standard)
        XCTAssertEqual(PolishLevel.standard.deterministicLevel, .standard)
        XCTAssertEqual(PolishLevel.off.deterministicLevel, .off)
    }

    func testHistorySearchMatching() {
        let entry = HistoryEntry(text: "Review the pull request",
                                 rawText: "review the the pull request",
                                 duration: 3, appName: "Slack", appBundleID: "com.tinyspeck.slackmacgap")
        XCTAssertTrue(entry.matches("PULL"))
        XCTAssertTrue(entry.matches("the the"))   // raw transcript is searchable
        XCTAssertTrue(entry.matches("slack"))     // so is the app name
        XCTAssertFalse(entry.matches("zoom"))
    }

    func testTrailingPressEnterStripped() {
        XCTAssertEqual(TrailingCommand.stripPressEnter("Sounds good, press enter"), "Sounds good")
        XCTAssertEqual(TrailingCommand.stripPressEnter("Ship it and press enter."), "Ship it")
        XCTAssertEqual(TrailingCommand.stripPressEnter("Done, then press return"), "Done")
        XCTAssertEqual(TrailingCommand.stripPressEnter("Press Enter"), "")
    }

    func testMidSentencePressEnterIgnored() {
        XCTAssertNil(TrailingCommand.stripPressEnter("You press enter to submit the form"))
        XCTAssertNil(TrailingCommand.stripPressEnter("The presenter was great"))
        XCTAssertNil(TrailingCommand.stripPressEnter("Just some normal text"))
    }

    func testAudioBackupRoundTrip() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples: [Float] = (0..<8000).map { sin(Float($0) * 0.01) }
        AudioBackup.save(samples: samples, to: url)
        let loaded = AudioBackup.load(from: url)
        XCTAssertEqual(loaded?.count, samples.count)
        XCTAssertEqual(loaded?[1234] ?? -1, samples[1234], accuracy: 0.0001)
    }

    func testForceLockBehavesLikeHandsFreeSession() {
        var engine = HotkeyEngine(hotkey: .default)
        engine.forceLock()
        XCTAssertTrue(engine.isLocked)
        // Esc finishes and commits, exactly like a double-tap lock.
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 53, flags: [], time: 1.0), .commit)
        XCTAssertFalse(engine.isLocked)
    }
}

final class CommandKeyEngineTests: XCTestCase {
    private let key = Hotkey.default.keyCode
    private let flag = Hotkey.default.modifierFlag!

    func testHoldCommitsCommand() {
        var engine = CommandKeyEngine(hotkey: .default)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0), .beginCommand)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 1.0), .commitCommand)
    }

    func testShortTapCancelsCommand() {
        var engine = CommandKeyEngine(hotkey: .default)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0), .beginCommand)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.05), .cancelCommand)
    }

    func testEscCancelsCommandHold() {
        var engine = CommandKeyEngine(hotkey: .default)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0)
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 53, flags: flag, time: 0.3), .cancelCommand)
        // The eventual release must not double-fire.
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.5), .none)
    }

    func testDoubleTapNeverLocks() {
        // A command is one held utterance — no hands-free variant, ever.
        var engine = CommandKeyEngine(hotkey: .default)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.05)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0.2)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.25), .cancelCommand)
    }

    func testOtherKeysFallThrough() {
        // .none = not consumed: the manager falls through to the main engine.
        var engine = CommandKeyEngine(hotkey: Hotkey(keyCode: 96, modifiers: 0, isModifierKey: false))
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 97, flags: [], time: 0), .none)
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 53, flags: [], time: 0.1), .none)
    }

    func testRegularKeyCommandHotkey() {
        var engine = CommandKeyEngine(hotkey: Hotkey(keyCode: 96, modifiers: 0, isModifierKey: false))
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 96, flags: [], time: 0), .beginCommand)
        XCTAssertEqual(engine.handle(type: .keyUp, keyCode: 96, flags: [], time: 0.5), .commitCommand)
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
        XCTAssertEqual(Hotkey.default.displayName, "Left ⌥")
        let withMods = Hotkey(keyCode: 49, modifiers: CGEventFlags.maskCommand.rawValue, isModifierKey: false)
        XCTAssertEqual(withMods.displayName, "⌘Space")
    }
}
