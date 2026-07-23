import AppKit
import Carbon.HIToolbox
import Combine

// Orchestrates the push-to-talk loop: hotkey → record → transcribe → inject.
// Owns the long-lived subsystem instances; publishes UI-facing state.
@MainActor
final class DictationController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcriberState: TranscriberState = .modelMissing
    // The primary model's own state while a fallback covers dictation —
    // drives "finishing setup in the background" UI. Mirrors transcriberState
    // when there's no fallback in play.
    @Published private(set) var upgradeState: TranscriberState = .modelMissing
    @Published private(set) var usingFallback = false

    let settings: SettingsStore
    let history: HistoryStore
    let transcriber: Transcriber
    private let recorder = AudioRecorder()
    private let injector = TextInjector()
    private let hotkeyManager: HotkeyManager
    private let indicator = RecordingIndicatorPanel()

    // Live typing: active only while a dictation runs with the setting on.
    private var liveSession: StreamingTranscription?
    private var liveUpdatesTask: Task<Void, Never>?
    private let liveTyper = LiveTyper()
    private var mouseMonitor: Any?

    // Test-observable last result (used by the "Try it" onboarding step too).
    @Published private(set) var lastTranscription: String = ""

    var micLevel: Float { recorder.currentLevel }

    private var cancellables: Set<AnyCancellable> = []

    init(settings: SettingsStore = .shared,
         history: HistoryStore = .shared,
         transcriber: Transcriber = SwitchingTranscriber(primary: ParakeetTranscriber(),
                                                         fallback: AppleSpeechTranscriber.makeIfSupported())) {
        self.settings = settings
        self.history = history
        self.transcriber = transcriber
        self.hotkeyManager = HotkeyManager(hotkey: settings.hotkey, handsFree: settings.handsFree)
        self.transcriberState = transcriber.state
        self.upgradeState = (transcriber as? SwitchingTranscriber)?.primaryState ?? transcriber.state
        hotkeyManager.onAction = { [weak self] action in
            self?.handle(action)
        }
        indicator.onStopHandsFree = { [weak self] in
            self?.hotkeyManager.endHandsFree()
        }
        settings.$handsFree
            .sink { [weak self] enabled in self?.hotkeyManager.handsFree = enabled }
            .store(in: &cancellables)
    }

    // MARK: lifecycle

    // Install the event tap. Returns false when Accessibility isn't granted.
    @discardableResult
    func startListening() -> Bool {
        hotkeyManager.hotkey = settings.hotkey
        return hotkeyManager.start()
    }

    func stopListening() {
        hotkeyManager.stop()
    }

    var isListening: Bool { hotkeyManager.isActive }

    func updateHotkey(_ hotkey: Hotkey) {
        settings.hotkey = hotkey
        hotkeyManager.hotkey = hotkey
    }

    // Shown briefly by SettingsView when opening Settings ended a session.
    @Published private(set) var showSettingsStopBanner = false
    private var bannerDismissTask: Task<Void, Never>?

    // Settings opened mid-dictation: recording into a window the user is now
    // configuring helps no one — end the session without committing. Text
    // already live-typed stays where it landed.
    func stopSessionForSettings() {
        guard phase == .recording else { return }
        hotkeyManager.abortSession()
        if phase == .recording { cancelRecording() }   // orphaned recording safety net
        showSettingsStopBanner = true
        bannerDismissTask?.cancel()
        bannerDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.showSettingsStopBanner = false
        }
    }

    // Download + warm the model, reporting progress into transcriberState
    // (or, when a fallback is already covering dictation, into upgradeState —
    // the effective state stays .ready and the finished model takes over
    // silently on the next dictation).
    func prepareModel() async {
        do {
            try await transcriber.prepare { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    self.upgradeState = .downloading(progress: progress)
                    if !self.usingFallback { self.transcriberState = .downloading(progress: progress) }
                }
            }
        } catch {
            // state already .failed inside the transcriber
        }
        refreshTranscriberState()
    }

    // MARK: fallback ("basic dictation")

    private var switcher: SwitchingTranscriber? { transcriber as? SwitchingTranscriber }

    var fallbackAvailable: Bool { switcher?.fallback != nil }

    // Bring up basic dictation so the app is usable before the model download
    // finishes. `interactive` marks an explicit user action (onboarding skip),
    // the only context allowed to show a permission prompt; quiet activation
    // (relaunch mid-download) backs off rather than surprise the user.
    @discardableResult
    func activateFallback(interactive: Bool) async -> Bool {
        // Only worth it while the model isn't even on disk; once downloaded,
        // loading takes seconds and the fallback would just add a permission
        // surface for nothing.
        guard let switcher, !switcher.modelIsDownloaded, switcher.primaryState != .ready
        else { return false }
        if !interactive && AppleSpeechTranscriber.wouldPromptForPermission { return false }
        let ok = await switcher.activateFallback()
        refreshTranscriberState()
        return ok
    }

    private func refreshTranscriberState() {
        transcriberState = transcriber.state
        upgradeState = switcher?.primaryState ?? transcriber.state
        usingFallback = switcher?.usingFallback ?? false
    }

    // MARK: push-to-talk

    private func handle(_ action: HotkeyAction) {
        switch action {
        case .begin: beginRecording()
        case .commit: commitRecording()
        case .cancel: cancelRecording()
        case .lock: indicator.showLocked()   // recording continues hands-free
        case .none: break
        }
    }

    private func playCue(_ name: String) {
        guard settings.soundCues else { return }
        if let sound = NSSound(named: NSSound.Name(name)) {
            sound.volume = 0.3
            sound.play()
        }
    }

    private func beginRecording() {
        guard phase == .idle || phase.isError else { return }
        guard transcriber.state == .ready else {
            // Not ready yet — flash the indicator with a hint instead of failing silently.
            indicator.showHint(transcriber.modelIsDownloaded
                               ? "Voice model is still warming up…"
                               : "Finish setup to start dictating")
            return
        }
        do {
            try recorder.start(deviceUID: settings.microphoneUID)
            phase = .recording
            playCue("Tink")
            refreshTranscriberState()   // pick up a background engine switch
            indicator.isBasic = usingFallback
            indicator.show(levelProvider: { [weak self] in self?.recorder.currentLevel ?? 0 })
            if settings.liveTyping { startLiveTyping() }
        } catch {
            phase = .error(error.localizedDescription)
            indicator.showHint("Couldn’t access the microphone")
        }
    }

    // MARK: live typing

    // After the user types mid-dictation, hold preview updates back until
    // their keyboard has been quiet this long — interleaving synthetic
    // keystrokes with real ones would garble both.
    private static let userEditHoldOff: TimeInterval = 1.0
    private var lastUserKeystroke: Date?

    private func startLiveTyping() {
        guard let session = transcriber.makeStreamingTranscription() else { return }
        liveSession = session
        liveTyper.reset()
        lastUserKeystroke = nil
        recorder.onChunk = { [weak session] chunk in session?.append(samples: chunk) }
        // If the user clicks somewhere or types themselves mid-dictation, the
        // cursor moved (or text was submitted — e.g. Enter in a chat box) and
        // our edits would land in the wrong place — rebase: leave what's on
        // screen be, keep dictating at the new cursor position. Aloud's own
        // synthetic keystrokes are stamped and ignored; Esc and a non-modifier
        // hotkey are session control, not editing.
        let hotkeyCode = settings.hotkey.keyCode
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            let isKeystroke = event.type == .keyDown
            if isKeystroke {
                if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == SyntheticEvent.marker { return }
                if event.keyCode == UInt16(kVK_Escape) || event.keyCode == hotkeyCode { return }
            }
            Task { @MainActor in
                guard let self else { return }
                if isKeystroke { self.lastUserKeystroke = Date() }
                self.liveTyper.rebase()
            }
        }
        liveUpdatesTask = Task { [weak self] in
            for await transcript in session.updates {
                guard let self, self.liveSession === session else { break }
                // Skip previews while the user is mid-edit; the transcript is
                // cumulative, so the next quiet update catches everything up.
                if let last = self.lastUserKeystroke,
                   Date().timeIntervalSince(last) < Self.userEditHoldOff { continue }
                let polisher = TextPolisher(level: self.settings.polishLevel,
                                            replacements: self.settings.replacements)
                self.liveTyper.apply(polisher.polish(transcript.full))
            }
        }
    }

    // Wait out the post-keystroke hold-off so a final apply can't interleave
    // with the user's own typing.
    private func waitForUserEditQuiet() async {
        while let last = lastUserKeystroke {
            let remaining = Self.userEditHoldOff - Date().timeIntervalSince(last)
            guard remaining > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
    }

    // Tear down live-typing state. The typed text itself is handled by the
    // caller first (final correction, erase, or leave as-is).
    private func endLiveTyping() {
        liveUpdatesTask?.cancel()
        liveUpdatesTask = nil
        liveSession = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        liveTyper.reset()
    }

    // Live commit: the streaming session was only ever a preview. The final
    // text comes from the same batch transcription as non-live mode (streamed
    // window boundaries can drop the odd word), and one last diff pass settles
    // whatever is on screen into that canonical result.
    private func commitLive(session: StreamingTranscription, samples: [Float]) {
        // The words are already on screen — flashing "Typing…" while the final
        // pass settles them reads as noise. Just dismiss the pill.
        indicator.hide()
        phase = .transcribing
        // Stop preview updates first so a late one can't race the final pass.
        liveUpdatesTask?.cancel()
        liveUpdatesTask = nil
        Task { await session.cancel() }
        guard Double(samples.count) / AudioRecorder.targetSampleRate >= 0.35 else {
            liveTyper.eraseAll()
            endLiveTyping()
            indicator.hide()
            phase = .idle
            return
        }
        Task {
            do {
                let result = try await transcriber.transcribe(samples: samples)
                let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let polisher = TextPolisher(level: settings.polishLevel,
                                            replacements: settings.replacements)
                let text = polisher.polish(raw)
                if !text.isEmpty {
                    await waitForUserEditQuiet()
                    liveTyper.apply(text)
                    history.append(HistoryEntry(text: text, rawText: raw, duration: result.audioDuration),
                                   limit: settings.historyLimit)
                    lastTranscription = text
                } else {
                    liveTyper.eraseAll()
                }
                endLiveTyping()
                indicator.hide()
                phase = .idle
            } catch {
                // Keep whatever was already typed — deleting words the user
                // watched appear would be worse than a rough tail.
                endLiveTyping()
                playCue("Basso")
                indicator.showHint("Couldn’t finish that dictation")
                phase = .error(error.localizedDescription)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if case .error = phase { phase = .idle }
            }
        }
    }

    private func commitRecording() {
        guard phase == .recording else { return }
        let samples = recorder.stop()
        if let session = liveSession {
            commitLive(session: session, samples: samples)
            return
        }
        // Sub-0.3 s audio is below the model's minimum — treat as accidental
        // tap and dismiss without ever flashing the "Typing…" state.
        guard Double(samples.count) / AudioRecorder.targetSampleRate >= 0.35 else {
            indicator.hide()
            phase = .idle
            return
        }
        indicator.showTranscribing()
        phase = .transcribing
        Task {
            do {
                let result = try await transcriber.transcribe(samples: samples)
                let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let polisher = TextPolisher(level: settings.polishLevel,
                                            replacements: settings.replacements)
                let text = polisher.polish(raw)
                if !text.isEmpty {
                    injector.inject(text)
                    history.append(HistoryEntry(text: text, rawText: raw, duration: result.audioDuration),
                                   limit: settings.historyLimit)
                    lastTranscription = text
                }
                indicator.hide()
                phase = .idle
            } catch {
                playCue("Basso")
                indicator.showHint("Couldn’t transcribe that — try again")
                phase = .error(error.localizedDescription)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if case .error = phase { phase = .idle }
            }
        }
    }

    private func cancelRecording() {
        guard phase == .recording else { return }
        recorder.cancel()
        if let session = liveSession {
            liveTyper.eraseAll()
            endLiveTyping()
            Task { await session.cancel() }
        }
        indicator.hide()
        phase = .idle
    }
}

private extension DictationController.Phase {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}
