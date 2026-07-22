import AppKit
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
         transcriber: Transcriber = ParakeetTranscriber()) {
        self.settings = settings
        self.history = history
        self.transcriber = transcriber
        self.hotkeyManager = HotkeyManager(hotkey: settings.hotkey, handsFree: settings.handsFree)
        self.transcriberState = transcriber.state
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

    // Download + warm the model, reporting progress into transcriberState.
    func prepareModel() async {
        do {
            try await transcriber.prepare { [weak self] progress in
                Task { @MainActor in
                    self?.transcriberState = .downloading(progress: progress)
                }
            }
        } catch {
            // state already .failed inside the transcriber
        }
        transcriberState = transcriber.state
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
            indicator.show(levelProvider: { [weak self] in self?.recorder.currentLevel ?? 0 })
            if settings.liveTyping { startLiveTyping() }
        } catch {
            phase = .error(error.localizedDescription)
            indicator.showHint("Couldn’t access the microphone")
        }
    }

    // MARK: live typing

    private func startLiveTyping() {
        guard let session = transcriber.makeStreamingTranscription() else { return }
        liveSession = session
        liveTyper.reset()
        recorder.onChunk = { [weak session] chunk in session?.append(samples: chunk) }
        // If the user clicks somewhere mid-dictation the cursor moves and our
        // edits would land in the wrong place — freeze and leave the text be.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.liveTyper.freeze() }
        }
        liveUpdatesTask = Task { [weak self] in
            for await transcript in session.updates {
                guard let self, self.liveSession === session else { break }
                let polisher = TextPolisher(level: self.settings.polishLevel,
                                            replacements: self.settings.replacements)
                self.liveTyper.apply(polisher.polish(transcript.full))
            }
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
        indicator.showTranscribing()
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
        indicator.showTranscribing()
        phase = .transcribing
        // Sub-0.3 s audio is below the model's minimum — treat as accidental tap.
        guard Double(samples.count) / AudioRecorder.targetSampleRate >= 0.35 else {
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
