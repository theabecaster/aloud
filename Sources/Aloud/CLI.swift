import AppKit
import Foundation

// Headless verbs so agents and CI can verify subsystems with no GUI and no
// human. See docs/testing.md. Every path here must run without TCC permissions
// except --inject (Accessibility) and --transcribe with live capture.
enum CLI {
    static func run(_ args: [String]) async -> Int32 {
        switch args.first {
        case "--version":
            print(Updater.currentVersion())
            return 0
        case "--doctor":
            return doctor()
        case "--selftest":
            return selfTest()
        case "--transcribe":
            guard args.count >= 2 else {
                FileHandle.standardError.write(Data("usage: Aloud --transcribe <audio-file>\n".utf8))
                return 2
            }
            return await transcribe(path: args[1])
        case "--inject":
            guard args.count >= 2 else {
                FileHandle.standardError.write(Data("usage: Aloud --inject <text>\n".utf8))
                return 2
            }
            return inject(text: args[1])
        default:
            FileHandle.standardError.write(Data("unknown flag \(args.first ?? "")\n".utf8))
            return 2
        }
    }

    // MARK: --doctor

    // Machine-readable status: permissions, model, paths, settings. Keep the
    // schema stable — tests and agents parse it.
    static func doctor() -> Int32 {
        let transcriber = ParakeetTranscriber()
        let settings = SettingsStore.shared
        let report: [String: Any] = [
            "version": Updater.currentVersion(),
            "permissions": [
                "microphone": Permissions.microphone.rawValue,
                "accessibility": Permissions.accessibility.rawValue,
            ],
            "model": [
                "downloaded": transcriber.modelIsDownloaded,
            ],
            "settings": [
                "hotkey": settings.hotkey.displayName,
                "launchAtLogin": settings.launchAtLogin,
                "microphoneUID": settings.microphoneUID ?? "default",
                "onboardingComplete": settings.onboardingComplete,
            ],
            "paths": [
                "stateDir": AppPaths.stateDir.path,
            ],
            "inputDevices": AudioDevices.inputDevices().map { $0.name },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report,
                                                  options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            print(s)
            return 0
        }
        return 1
    }

    // MARK: --transcribe

    static func transcribe(path: String) async -> Int32 {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("no such file: \(path)\n".utf8))
            return 2
        }
        let transcriber = ParakeetTranscriber()
        do {
            let progressPrinter = ProgressPrinter()
            try await transcriber.prepare { progress in
                progressPrinter.report(progress)
            }
            let result = try await transcriber.transcribe(file: url)
            print(result.text)
            FileHandle.standardError.write(Data(
                String(format: "confidence=%.2f audio=%.2fs processing=%.2fs\n",
                       result.confidence, result.audioDuration, result.processingTime).utf8))
            return 0
        } catch {
            FileHandle.standardError.write(Data("transcription failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    // Thread-safe download progress → stderr, deciled so logs stay short.
    final class ProgressPrinter: @unchecked Sendable {
        private let lock = NSLock()
        private var lastDecile = -1

        func report(_ progress: Double) {
            let decile = Int(progress * 10)
            lock.lock(); defer { lock.unlock() }
            guard decile != lastDecile else { return }
            lastDecile = decile
            FileHandle.standardError.write(Data("model download: \(decile * 10)%\n".utf8))
        }
    }

    // MARK: --inject

    static func inject(text: String) -> Int32 {
        guard Permissions.accessibility == .granted else {
            FileHandle.standardError.write(Data("accessibility permission not granted\n".utf8))
            return 1
        }
        let injector = TextInjector()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            injector.inject(text) { sem.signal() }
        }
        // Pump the main runloop so the delayed restore fires.
        let deadline = Date().addingTimeInterval(TextInjector.restoreDelay + 2)
        while sem.wait(timeout: .now()) != .success && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return 0
    }

    // MARK: --selftest

    // In-process checks needing no TCC grants and no model. Exit 0 = pass.
    static func selfTest() -> Int32 {
        var failures: [String] = []
        func expect(_ cond: Bool, _ name: String) {
            if cond { print("ok  \(name)") } else { print("FAIL \(name)"); failures.append(name) }
        }

        // Isolate state.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        setenv("ALOUD_STATE_DIR", tmp.path, 1)

        // 1. Hotkey engine: hold/commit, short-tap cancel, Esc cancel — pure logic.
        var engine = HotkeyEngine(hotkey: .default)
        let flag = Hotkey.default.modifierFlag!
        expect(engine.handle(type: .flagsChanged, keyCode: 54, flags: flag, time: 0) == .begin,
               "hotkey: modifier down begins")
        expect(engine.handle(type: .flagsChanged, keyCode: 54, flags: [], time: 0.5) == .commit,
               "hotkey: release after hold commits")
        _ = engine.handle(type: .flagsChanged, keyCode: 54, flags: flag, time: 1.0)
        expect(engine.handle(type: .flagsChanged, keyCode: 54, flags: [], time: 1.05) == .cancel,
               "hotkey: short tap cancels")
        _ = engine.handle(type: .flagsChanged, keyCode: 54, flags: flag, time: 2.0)
        expect(engine.handle(type: .keyDown, keyCode: 53, flags: flag, time: 2.2) == .cancel,
               "hotkey: esc while held cancels")
        var keyEngine = HotkeyEngine(hotkey: Hotkey(keyCode: 96, modifiers: 0, isModifierKey: false))
        expect(keyEngine.handle(type: .keyDown, keyCode: 96, flags: [], time: 0) == .begin,
               "hotkey: regular key begins")
        expect(keyEngine.handle(type: .keyUp, keyCode: 96, flags: [], time: 0.4) == .commit,
               "hotkey: regular key commits")
        expect(keyEngine.handle(type: .keyDown, keyCode: 97, flags: [], time: 1) == .none,
               "hotkey: other keys ignored")

        // 2. Hotkey persistence round-trip.
        let hk = Hotkey(keyCode: 96, modifiers: CGEventFlags.maskCommand.rawValue, isModifierKey: false)
        if let encoded = try? JSONEncoder().encode(hk),
           let decoded = try? JSONDecoder().decode(Hotkey.self, from: encoded) {
            expect(decoded == hk, "hotkey: codable round-trip")
        } else { expect(false, "hotkey: codable round-trip") }

        // 3. History store round-trip in the temp dir.
        let historyURL = tmp.appendingPathComponent("history.json")
        let store = HistoryStore(fileURL: historyURL)
        store.append(HistoryEntry(text: "hello world", duration: 1.2), limit: 50)
        store.append(HistoryEntry(text: "second", duration: 0.8), limit: 50)
        expect(store.entries.count == 2 && store.entries[0].text == "second",
               "history: append order")
        Thread.sleep(forTimeInterval: 0.3)   // async persist
        let reloaded = HistoryStore(fileURL: historyURL)
        expect(reloaded.entries.count == 2, "history: persisted + reloaded")
        store.clear()
        expect(store.entries.isEmpty, "history: clear")

        // 4. History limit enforcement.
        let limited = HistoryStore(fileURL: tmp.appendingPathComponent("h2.json"))
        for i in 0..<10 { limited.append(HistoryEntry(text: "e\(i)", duration: 0), limit: 5) }
        expect(limited.entries.count == 5 && limited.entries[0].text == "e9",
               "history: limit enforced")

        // 5. Injector pasteboard save/restore on a private board (no ⌘V posting).
        let board = NSPasteboard(name: NSPasteboard.Name("aloud-selftest-\(getpid())"))
        board.clearContents()
        board.setString("user clipboard", forType: .string)
        let injector = TextInjector(pasteboard: board, postEvents: false)
        let snap = injector.snapshot()
        board.clearContents()
        board.setString("dictated text", forType: .string)
        expect(board.string(forType: .string) == "dictated text", "injector: text staged")
        injector.restore(snap)
        expect(board.string(forType: .string) == "user clipboard", "injector: clipboard restored")

        // 6. Updater semver.
        expect(Updater.semverLess("1.0.0", "1.0.1"), "updater: patch compare")
        expect(Updater.semverLess("v1.9.0", "v1.10.0"), "updater: no lexicographic trap")
        expect(!Updater.semverLess("2.0.0", "1.9.9"), "updater: not less")

        // 7. Doctor JSON emits and parses.
        expect(doctor() == 0, "doctor: runs")

        // 8. Settings store round-trip in an isolated suite.
        let suiteName = "aloud-selftest-\(getpid())"
        if let d = UserDefaults(suiteName: suiteName) {
            d.removePersistentDomain(forName: suiteName)
            let s = SettingsStore(defaults: d)
            s.hotkey = hk
            s.launchAtLogin = true
            let s2 = SettingsStore(defaults: d)
            expect(s2.hotkey == hk && s2.launchAtLogin, "settings: round-trip")
            d.removePersistentDomain(forName: suiteName)
        } else { expect(false, "settings: round-trip") }

        print(failures.isEmpty ? "\nselftest passed" : "\nselftest FAILED: \(failures.joined(separator: ", "))")
        return failures.isEmpty ? 0 : 1
    }
}
