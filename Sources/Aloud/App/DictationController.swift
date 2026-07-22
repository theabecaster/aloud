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

    // Test-observable last result (used by the "Try it" onboarding step too).
    @Published private(set) var lastTranscription: String = ""

    var micLevel: Float { recorder.currentLevel }

    init(settings: SettingsStore = .shared,
         history: HistoryStore = .shared,
         transcriber: Transcriber = ParakeetTranscriber()) {
        self.settings = settings
        self.history = history
        self.transcriber = transcriber
        self.hotkeyManager = HotkeyManager(hotkey: settings.hotkey)
        self.transcriberState = transcriber.state
        hotkeyManager.onAction = { [weak self] action in
            self?.handle(action)
        }
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
        case .none: break
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
            indicator.show(levelProvider: { [weak self] in self?.recorder.currentLevel ?? 0 })
        } catch {
            phase = .error(error.localizedDescription)
            indicator.showHint("Couldn’t access the microphone")
        }
    }

    private func commitRecording() {
        guard phase == .recording else { return }
        let samples = recorder.stop()
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
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    injector.inject(text)
                    history.append(HistoryEntry(text: text, duration: result.audioDuration),
                                   limit: settings.historyLimit)
                    lastTranscription = text
                }
                indicator.hide()
                phase = .idle
            } catch {
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
