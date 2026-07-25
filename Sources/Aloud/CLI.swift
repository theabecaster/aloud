import AppKit
import AVFoundation
import Carbon.HIToolbox
import Foundation

// Headless verbs so agents and CI can verify subsystems with no GUI and no
// human. Every path here must run without TCC permissions
// except --inject (Accessibility) and --transcribe with live capture.
enum CLI {
    static func run(_ args: [String]) async -> Int32 {
        switch args.first {
        case "--version":
            print(Updater.currentVersion())
            return 0
        case "--doctor":
            return doctor()
        case "--enhance":
            // Headless probe of the on-device rewrite: text in, rewrite out.
            // Optional second arg: a per-app mode (messaging|email|notes|…)
            // whose tone instruction rides along, for probing the tones.
            // Exit 2 when the engine isn't available on this machine.
            guard args.count >= 2 else {
                FileHandle.standardError.write(Data("usage: Aloud --enhance <text> [mode]\n".utf8))
                return 64
            }
            var mode: DictationMode?
            if args.count >= 3 {
                guard let m = DictationMode(rawValue: args[2]) else {
                    let names = DictationMode.allCases.map(\.rawValue).joined(separator: "|")
                    FileHandle.standardError.write(Data("unknown mode \(args[2]) (\(names))\n".utf8))
                    return 64
                }
                mode = m
            }
            guard let enhancer = EnhancerFactory.make(), enhancer.isAvailable else {
                FileHandle.standardError.write(Data("enhancer unavailable on this machine\n".utf8))
                return 2
            }
            do {
                print(try await enhancer.enhance(args[1], extraInstructions: mode?.toneInstruction))
                return 0
            } catch {
                FileHandle.standardError.write(Data("enhance failed: \(error)\n".utf8))
                return 1
            }
        case "--command":
            // Headless probe of the voice-command path: parse the instruction
            // with guided generation, execute it against an optional selection
            // (rewrite) or from scratch (generate), print the result. Exit 2
            // when the engine isn't available on this machine.
            guard args.count >= 2 else {
                FileHandle.standardError.write(Data(
                    "usage: Aloud --command <instruction> [--selection <text>]\n".utf8))
                return 64
            }
            var selection: String?
            if let idx = args.firstIndex(of: "--selection"), args.count > idx + 1 {
                selection = args[idx + 1]
            }
            return await command(instruction: args[1], selection: selection)
        case "--selftest":
            return selfTest()
        case "--transcribe":
            guard args.count >= 2 else {
                FileHandle.standardError.write(Data("usage: Aloud --transcribe <audio-file>\n".utf8))
                return 2
            }
            return await transcribe(path: args[1])
        case "--transcribe-basic":
            // Same as --transcribe but through the system fallback engine
            // ("basic dictation") — verifies the degraded path headlessly.
            // May need the Speech Recognition permission on macOS < 26.
            guard args.count >= 2 else {
                FileHandle.standardError.write(Data("usage: Aloud --transcribe-basic <audio-file>\n".utf8))
                return 2
            }
            return await transcribeBasic(path: args[1])
        case "--transcribe-live":
            // Streaming-path twin of --transcribe: feeds the file through a
            // live session in chunks, printing each update to stderr and the
            // final text to stdout. Verifies the live-typing engine headlessly.
            // Optional second arg: playback speed multiple (e.g. 1 = realtime,
            // 4 = 4× faster). Omitted = as fast as possible (single update).
            guard args.count >= 2 else {
                FileHandle.standardError.write(Data("usage: Aloud --transcribe-live <audio-file> [speed]\n".utf8))
                return 2
            }
            let speed = args.count >= 3 ? Double(args[2]) : nil
            return await transcribeLive(path: args[1], speed: speed)
        case "--update-check":
            // Headless updater probe: prints current vs latest and whether an
            // update would apply. Never installs (the GUI owns that).
            let current = Updater.currentVersion()
            guard let latest = Updater.fetchLatestRelease() else {
                FileHandle.standardError.write(Data("couldn't reach the release feed\n".utf8))
                return 1
            }
            let newer = Updater.semverLess(current, latest.tag)
            print("current=\(current) latest=\(latest.tag) update_available=\(newer)")
            return 0
        case "--simulate-hold":
            // Posts a synthetic press-hold-release of the configured hotkey so
            // scripts/loop-test.sh can exercise the running GUI's real event
            // tap + recorder + injector. Requires Accessibility.
            let seconds = args.count >= 2 ? (Double(args[1]) ?? 3.0) : 3.0
            return simulateHold(seconds: seconds)
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

    // MARK: --command

    static func command(instruction: String, selection: String?) async -> Int32 {
        guard let interpreter = CommandInterpreterFactory.make(), interpreter.isAvailable else {
            FileHandle.standardError.write(Data("command engine unavailable on this machine\n".utf8))
            return 2
        }
        do {
            let intent = try await interpreter.parse(instruction)
            FileHandle.standardError.write(Data(
                "action=\(intent.action.rawValue) instruction='\(intent.instruction)' route=\(intent.route(hasSelection: !(selection ?? "").isEmpty))\n".utf8))
            let result: String
            switch intent.route(hasSelection: !(selection ?? "").isEmpty) {
            case .rewrite:
                result = try await interpreter.rewrite(selection ?? "", instruction: intent.instruction)
            case .generate:
                result = try await interpreter.generate(intent.instruction)
            case .translate(let language):
                result = try await interpreter.translate(selection ?? "", to: language)
            }
            print(result)
            return 0
        } catch {
            FileHandle.standardError.write(Data("command failed: \(error)\n".utf8))
            return 1
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
                "liveTyping": settings.liveTyping,
                "handsFree": settings.handsFree,
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

    // MARK: --transcribe-basic

    static func transcribeBasic(path: String) async -> Int32 {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("no such file: \(path)\n".utf8))
            return 2
        }
        guard let transcriber = AppleSpeechTranscriber.makeIfSupported() else {
            FileHandle.standardError.write(Data("basic dictation unsupported on this system\n".utf8))
            return 1
        }
        do {
            try await transcriber.prepare { _ in }
            let result = try await transcriber.transcribe(file: url)
            print(result.text)
            FileHandle.standardError.write(Data(
                String(format: "audio=%.2fs processing=%.2fs\n",
                       result.audioDuration, result.processingTime).utf8))
            return 0
        } catch {
            FileHandle.standardError.write(Data("basic transcription failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    // MARK: --transcribe-live

    static func transcribeLive(path: String, speed: Double? = nil) async -> Int32 {
        let url = URL(fileURLWithPath: path)
        guard let samples = loadSamples16k(url) else {
            FileHandle.standardError.write(Data("couldn't read audio: \(path)\n".utf8))
            return 2
        }
        let transcriber = ParakeetTranscriber()
        do {
            let progressPrinter = ProgressPrinter()
            try await transcriber.prepare { progressPrinter.report($0) }
            guard let session = transcriber.makeStreamingTranscription() else {
                FileHandle.standardError.write(Data("engine has no streaming support\n".utf8))
                return 1
            }
            let printer = Task {
                for await update in session.updates {
                    FileHandle.standardError.write(Data(
                        "confirmed='\(update.confirmed)' volatile='\(update.volatile)'\n".utf8))
                }
            }
            // Half-second chunks, like the mic tap would deliver.
            let chunkSize = 8_000
            var index = 0
            while index < samples.count {
                let end = min(index + chunkSize, samples.count)
                session.append(samples: Array(samples[index..<end]))
                index = end
                if let speed, speed > 0 {
                    let chunkSeconds = Double(chunkSize) / 16_000 / speed
                    try? await Task.sleep(nanoseconds: UInt64(chunkSeconds * 1_000_000_000))
                }
            }
            let result = try await session.finish()
            await printer.value
            print(result.text)
            return 0
        } catch {
            FileHandle.standardError.write(Data("live transcription failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    // Decode any readable audio file to 16 kHz mono Float32.
    private static func loadSamples16k(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sourceFormat = file.processingFormat
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: target),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                              frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do { try file.read(into: inBuffer) } catch { return nil }
        let ratio = target.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: outBuffer, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return inBuffer
        }
        guard err == nil, let ch = outBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuffer.frameLength)))
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

    // MARK: --simulate-hold

    static func simulateHold(seconds: Double) -> Int32 {
        guard Permissions.accessibility == .granted else {
            FileHandle.standardError.write(Data("accessibility permission not granted\n".utf8))
            return 1
        }
        let hotkey = SettingsStore.shared.hotkey
        guard hotkey.isModifierKey else {
            FileHandle.standardError.write(Data("--simulate-hold currently supports modifier hotkeys only\n".utf8))
            return 2
        }
        // Each chord member is a (virtual keycode, flag bit) pair; a lone
        // modifier is a chord of one. Press in order with cumulative flags,
        // release in reverse — the same event stream real keys produce.
        let members: [(key: CGKeyCode, flag: CGEventFlags)]
        if hotkey.isChord {
            let all: [(CGEventFlags, Int)] = [(.maskControl, kVK_Control), (.maskAlternate, kVK_Option),
                                              (.maskShift, kVK_Shift), (.maskCommand, kVK_Command)]
            members = all.filter { hotkey.chordMask.contains($0.0) }
                .map { (CGKeyCode($0.1), $0.0) }
        } else if let flag = hotkey.modifierFlag {
            members = [(CGKeyCode(hotkey.keyCode), flag)]
        } else {
            FileHandle.standardError.write(Data("--simulate-hold currently supports modifier hotkeys only\n".utf8))
            return 2
        }
        let source = CGEventSource(stateID: .hidSystemState)
        func post(key: CGKeyCode, flags: CGEventFlags) {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: !flags.isEmpty) else { return }
            e.type = .flagsChanged
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
        FileHandle.standardError.write(Data("holding \(hotkey.displayName) for \(seconds)s\n".utf8))
        var held: CGEventFlags = []
        for m in members {
            held.insert(m.flag)
            post(key: m.key, flags: held)
        }
        Thread.sleep(forTimeInterval: seconds)
        for m in members.reversed() {
            held.remove(m.flag)
            post(key: m.key, flags: held)
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

        // 1. Hotkey engine: hold/commit, short-tap cancel, Esc, hands-free — pure logic.
        let lone = Hotkey(keyCode: UInt16(kVK_Option), modifiers: 0, isModifierKey: true)
        var engine = HotkeyEngine(hotkey: lone)
        let key = lone.keyCode
        let flag = lone.modifierFlag!
        expect(engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0) == .begin,
               "hotkey: modifier down begins")
        expect(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.5) == .commit,
               "hotkey: release after hold commits")
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 1.0)
        expect(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 1.05) == .cancel,
               "hotkey: short tap cancels")
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 2.0)
        expect(engine.handle(type: .keyDown, keyCode: 53, flags: flag, time: 2.2) == .cancel,
               "hotkey: esc while held cancels")
        // Hands-free: double-press locks, hotkey taps are then ignored, Esc finishes.
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 3.0)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 3.05)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 3.2)
        expect(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 3.25) == .lock,
               "hotkey: double-press locks hands-free")
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 4.0)
        expect(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 4.6) == .none,
               "hotkey: taps ignored while locked")
        expect(engine.handle(type: .keyDown, keyCode: 53, flags: [], time: 5.0) == .commit,
               "hotkey: esc finishes hands-free")
        // Double-tapping the hotkey again also finishes hands-free, without
        // re-arming a new session.
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 6.0)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 6.05)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 6.2)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 6.25)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 7.0)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 7.05)
        expect(engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 7.2) == .commit,
               "hotkey: double-tap finishes hands-free")
        expect(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 7.25) == .none,
               "hotkey: stopping tap release swallowed")
        var noHandsFree = HotkeyEngine(hotkey: lone, handsFreeEnabled: false)
        _ = noHandsFree.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0)
        _ = noHandsFree.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.05)
        _ = noHandsFree.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0.2)
        expect(noHandsFree.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.25) == .cancel,
               "hotkey: hands-free off means double-press never locks")
        // Command key engine: same hold semantics, relabeled actions, no lock.
        var commandEngine = CommandKeyEngine(hotkey: lone)
        expect(commandEngine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0) == .beginCommand,
               "command key: press begins")
        expect(commandEngine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.5) == .commitCommand,
               "command key: release after hold commits")
        _ = commandEngine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 1.0)
        expect(commandEngine.handle(type: .keyDown, keyCode: 53, flags: flag, time: 1.2) == .cancelCommand,
               "command key: esc while held cancels")
        _ = commandEngine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 1.3)
        _ = commandEngine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 2.0)
        _ = commandEngine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 2.05)
        _ = commandEngine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 2.2)
        expect(commandEngine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 2.25) == .cancelCommand,
               "command key: double-tap never locks")
        expect(commandEngine.handle(type: .keyDown, keyCode: 97, flags: [], time: 3.0) == HotkeyAction.none,
               "command key: other keys fall through")

        // Command routing + generated-output checks — pure, no model needed.
        let intent = CommandIntent(action: .generate, instruction: "fix the grammar")
        expect(intent.route(hasSelection: true) == .rewrite,
               "command: selection routes to rewrite")
        expect(intent.route(hasSelection: false) == .generate,
               "command: no selection routes to generate")
        expect(CommandOutputCheck.validateGenerated(" Hi there ") == "Hi there",
               "command: generated output trimmed")
        expect(CommandOutputCheck.validateGenerated("```code```") == nil,
               "command: code fences rejected")
        let translateIntent = CommandIntent(action: .translate, instruction: "translate to Spanish",
                                            language: "Spanish")
        expect(translateIntent.route(hasSelection: true) == .translate("Spanish"),
               "command: translate routes with a selection")
        expect(LanguageResolver.language(named: "Spanish")?.languageCode?.identifier == "es",
               "command: language name resolves to code")
        expect(LanguageResolver.language(named: "not a language") == nil,
               "command: unknown language resolves to nil")

        var keyEngine = HotkeyEngine(hotkey: Hotkey(keyCode: 96, modifiers: 0, isModifierKey: false))
        expect(keyEngine.handle(type: .keyDown, keyCode: 96, flags: [], time: 0) == .begin,
               "hotkey: regular key begins")
        expect(keyEngine.handle(type: .keyUp, keyCode: 96, flags: [], time: 0.4) == .commit,
               "hotkey: regular key commits")
        expect(keyEngine.handle(type: .keyDown, keyCode: 97, flags: [], time: 1) == .none,
               "hotkey: other keys ignored")

        // Modifier chords: exact set pressed together begins, any member up
        // commits, a foreign key right after the press means it was a
        // shortcut and cancels, and releasing down *into* the set never fires.
        let ctrl = UInt16(kVK_Control), opt = UInt16(kVK_Option), cmd = UInt16(kVK_Command)
        var chordEngine = HotkeyEngine(hotkey: .default)   // ⌃⌥
        expect(chordEngine.handle(type: .flagsChanged, keyCode: ctrl, flags: .maskControl, time: 0) == HotkeyAction.none,
               "chord: half the chord does nothing")
        expect(chordEngine.handle(type: .flagsChanged, keyCode: opt, flags: [.maskControl, .maskAlternate], time: 0.05) == .begin,
               "chord: full chord begins")
        expect(chordEngine.handle(type: .flagsChanged, keyCode: opt, flags: .maskControl, time: 0.6) == .commit,
               "chord: releasing a member commits")
        _ = chordEngine.handle(type: .flagsChanged, keyCode: ctrl, flags: [], time: 0.65)
        _ = chordEngine.handle(type: .flagsChanged, keyCode: ctrl, flags: .maskControl, time: 2.0)
        _ = chordEngine.handle(type: .flagsChanged, keyCode: opt, flags: [.maskControl, .maskAlternate], time: 2.05)
        expect(chordEngine.handle(type: .keyDown, keyCode: 123, flags: [.maskControl, .maskAlternate], time: 2.2) == .cancel,
               "chord: foreign key inside grace window cancels")
        expect(chordEngine.handle(type: .flagsChanged, keyCode: opt, flags: .maskControl, time: 2.5) == HotkeyAction.none,
               "chord: release after a cancel stays quiet")
        _ = chordEngine.handle(type: .flagsChanged, keyCode: ctrl, flags: [], time: 2.55)
        // Arrived from above (⌃⌥⌘ minus ⌘) — not a press, must not begin.
        _ = chordEngine.handle(type: .flagsChanged, keyCode: ctrl, flags: .maskControl, time: 3.0)
        _ = chordEngine.handle(type: .flagsChanged, keyCode: opt, flags: [.maskControl, .maskAlternate], time: 3.02)
        _ = chordEngine.handle(type: .flagsChanged, keyCode: cmd, flags: [.maskControl, .maskAlternate, .maskCommand], time: 3.03)
        var lateEngine = HotkeyEngine(hotkey: .default)
        _ = lateEngine.handle(type: .flagsChanged, keyCode: ctrl, flags: .maskControl, time: 3.0)
        _ = lateEngine.handle(type: .flagsChanged, keyCode: cmd, flags: [.maskControl, .maskCommand], time: 3.01)
        expect(lateEngine.handle(type: .flagsChanged, keyCode: cmd, flags: [.maskControl, .maskAlternate], time: 3.1) == HotkeyAction.none,
               "chord: reached by releasing another modifier never begins")
        // A brushed key after the grace window is ignored, not a cancel.
        var longHold = HotkeyEngine(hotkey: .default)
        _ = longHold.handle(type: .flagsChanged, keyCode: ctrl, flags: .maskControl, time: 10)
        _ = longHold.handle(type: .flagsChanged, keyCode: opt, flags: [.maskControl, .maskAlternate], time: 10.05)
        expect(longHold.handle(type: .keyDown, keyCode: 11, flags: [.maskControl, .maskAlternate], time: 11.0) == HotkeyAction.none,
               "chord: stray key after grace window is ignored")
        expect(longHold.handle(type: .flagsChanged, keyCode: opt, flags: .maskControl, time: 12.0) == .commit,
               "chord: long hold still commits")

        // Overlap rules: containment conflicts, partial overlap doesn't.
        expect(Hotkey.default.overlaps(Hotkey.chord([.maskControl, .maskAlternate, .maskCommand])),
               "overlap: ⌃⌥ conflicts with ⌃⌥⌘")
        expect(!Hotkey.default.overlaps(Hotkey.defaultHandsFreeKey),
               "overlap: ⌃⌥ coexists with ⌃⇧")
        expect(Hotkey(keyCode: UInt16(kVK_Option), modifiers: 0, isModifierKey: true)
            .overlaps(Hotkey.default),
               "overlap: lone ⌥ conflicts with ⌃⌥")
        expect(!Hotkey(keyCode: UInt16(kVK_Option), modifiers: 0, isModifierKey: true)
            .overlaps(Hotkey(keyCode: UInt16(kVK_RightOption), modifiers: 0, isModifierKey: true)),
               "overlap: left ⌥ coexists with right ⌥")
        expect(Hotkey(keyCode: 49, modifiers: CGEventFlags.maskCommand.rawValue, isModifierKey: false)
            .overlaps(Hotkey(keyCode: UInt16(kVK_Command), modifiers: 0, isModifierKey: true)),
               "overlap: lone ⌘ conflicts with ⌘Space")

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

        // 6. Live-typing diff + headless typer state machine.
        let diff = TypedTextDiff.from("I went their", to: "I went there today")
        expect(diff.backspaces == 2 && diff.insertion == "re today", "livetyper: diff rewinds to divergence")
        expect(TypedTextDiff.from("ok 👍🏽", to: "ok 🎉").backspaces == 1, "livetyper: grapheme backspaces")
        let typer = LiveTyper(postEvents: false)
        typer.apply("hello")
        typer.apply("hello world")
        let tracked = typer.typed == "hello world"
        typer.rebase()
        typer.apply("hello world again")
        let rebased = typer.typed == " again"
        typer.eraseAll()
        expect(tracked && rebased && typer.typed.isEmpty,
               "livetyper: tracks text, rebase continues with tail only")

        // 6b. Spoken numbers written back out — and prose left alone.
        var numberPolisher = TextPolisher(level: .standard, replacements: [])
        numberPolisher.capitalizeNames = false
        expect(numberPolisher.polish("meet me at three thirty p.m.") == "Meet me at 3:30 PM",
               "numbers: spoken time becomes a written one")
        expect(numberPolisher.polish("one of them left") == "One of them left",
               "numbers: prose keeps its words")

        // 7. Updater semver.
        expect(Updater.semverLess("1.0.0", "1.0.1"), "updater: patch compare")
        expect(Updater.semverLess("v1.9.0", "v1.10.0"), "updater: no lexicographic trap")
        expect(!Updater.semverLess("2.0.0", "1.9.9"), "updater: not less")

        // 8. Doctor JSON emits and parses.
        expect(doctor() == 0, "doctor: runs")

        // 9. Settings store round-trip in an isolated suite.
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
