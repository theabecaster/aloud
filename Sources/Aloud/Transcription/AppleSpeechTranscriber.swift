import AVFoundation
import Foundation
import Speech

// System-provided fallback engine ("basic dictation"): lets dictation work
// before the primary voice model has finished its one-time download, entirely
// on-device. macOS 26+ uses the modern SpeechAnalyzer pipeline; earlier
// systems use the legacy on-device recognizer (which needs the separate
// Speech Recognition permission — only ever requested from an explicit user
// action, see prepare()). UI copy never names either engine.
final class AppleSpeechTranscriber: Transcriber {
    private(set) var state: TranscriberState = .modelMissing
    private var locale: Locale?
    // The declared languages `locale` was resolved from. Kept so a re-resolve
    // can tell whether the locale in hand is answering the list as it stands
    // now — see relocalize().
    private var resolvedFor: [String] = []
    private let prepareLock = AsyncSerialGate()

    // Nil when this system can't provide a usable on-device fallback at all.
    static func makeIfSupported() -> AppleSpeechTranscriber? {
        if #available(macOS 26, *) { return AppleSpeechTranscriber() }
        // Legacy: an on-device recognizer must exist for a candidate locale
        // and the permission must not already be hard-denied.
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized || status == .notDetermined else { return nil }
        guard Self.legacyRecognizer() != nil else { return nil }
        return AppleSpeechTranscriber()
    }

    // True when activating the fallback would show a permission dialog —
    // callers use this to avoid surprise prompts outside onboarding.
    static var wouldPromptForPermission: Bool {
        if #available(macOS 26, *) { return false }
        return SFSpeechRecognizer.authorizationStatus() == .notDetermined
    }

    // Declared dictation languages first (the user told us what they speak),
    // then the system locale, then English as the always-available floor.
    private static var localeCandidates: [Locale] {
        declaredLanguages.map { Locale(identifier: $0) }
            + [Locale.current, Locale(identifier: "en_US")]
    }

    private static var declaredLanguages: [String] {
        SettingsStore.shared.declaredLanguages
    }

    // A declared language is a bare code ("pt"); recognizer locales are
    // regioned ("pt-BR"). Prefer an exact locale, settle for any region of
    // the same language.
    private static func resolve(from supported: [Locale]) -> Locale? {
        for candidate in localeCandidates {
            if let exact = supported.first(where: {
                $0.identifier(.bcp47) == candidate.identifier(.bcp47)
            }) { return exact }
            if let sameLanguage = supported.first(where: {
                $0.language.languageCode == candidate.language.languageCode
            }) { return sameLanguage }
        }
        return nil
    }

    private static func legacyRecognizer() -> SFSpeechRecognizer? {
        guard let locale = resolve(from: Array(SFSpeechRecognizer.supportedLocales())) else {
            return nil
        }
        if let rec = SFSpeechRecognizer(locale: locale), rec.supportsOnDeviceRecognition {
            return rec
        }
        // The best language match may lack on-device support — fall back to
        // anything that has it rather than lose basic dictation entirely.
        for candidate in [Locale.current, Locale(identifier: "en_US")] {
            if let rec = SFSpeechRecognizer(locale: candidate), rec.supportsOnDeviceRecognition {
                return rec
            }
        }
        return nil
    }

    // "Downloaded" here means ready to use without further setup. The modern
    // pipeline's assets are system-managed and small; treat prepared as done.
    var modelIsDownloaded: Bool { state == .ready }

    func prepare(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await prepareLock.run { [self] in
            if state == .ready { return }
            state = .loading
            do {
                if #available(macOS 26, *) {
                    try await prepareModern()
                } else {
                    try await prepareLegacy()
                }
                state = .ready
            } catch {
                state = .failed(error.localizedDescription)
                throw error
            }
        }
    }

    @available(macOS 26, *)
    private func prepareModern() async throws {
        // Read before the awaits below, so what gets recorded is the list this
        // resolve actually answered rather than whatever it has become by the
        // time an asset install finishes.
        let declared = Self.declaredLanguages
        let supported = await SpeechTranscriber.supportedLocales
        guard let match = Self.resolve(from: supported) else {
            throw AppleSpeechError.unavailable
        }
        // System-managed asset install; a no-op when already present. Needs
        // network the first time, so this can fail offline — callers surface
        // that as "basic dictation isn't available right now".
        let transcriber = SpeechTranscriber(locale: match, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        locale = match
        resolvedFor = declared
    }

    private func prepareLegacy() async throws {
        let declared = Self.declaredLanguages
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
            }
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = Self.legacyRecognizer() else {
            throw AppleSpeechError.unavailable
        }
        locale = recognizer.locale
        resolvedFor = declared
    }

    // The declared dictation languages chose this engine's locale, once, at
    // prepare. `prepare` returns early once ready, so without this a language
    // added in Settings → Dictation would not reach basic dictation until the
    // next launch — and that pane puts the Languages list directly under the
    // banner saying basic dictation is the engine in use.
    //
    // A failed re-resolve (the modern path installs assets, which needs
    // network) keeps the locale already in hand: losing basic dictation
    // because someone added a language would be worse than the stale locale
    // this exists to fix.
    func relocalize() async {
        guard state == .ready else { return }
        // The gate coalesces: a re-resolve arriving while a prepare is already
        // running joins that one rather than starting its own — and that one
        // may have read the language list before the change that prompted
        // this. So ask by result, not by call: keep going until the locale in
        // hand was resolved from the list as it stands. Bounded, because a
        // resolve that keeps failing must not spin.
        for _ in 0..<3 {
            guard resolvedFor != Self.declaredLanguages else { return }
            do {
                try await prepareLock.run { [self] in
                    if #available(macOS 26, *) {
                        try await prepareModern()
                    } else {
                        try await prepareLegacy()
                    }
                }
            } catch {
                return
            }
        }
    }

    func transcribe(samples: [Float]) async throws -> Transcription {
        // Detached: this is called from main-actor contexts, and the WAV
        // write is synchronous disk I/O — off the caller's actor so a slow
        // disk moment never holds up the UI.
        let url = try await Task.detached(priority: .userInitiated) {
            try Self.writeTempWav(samples: samples)
        }.value
        defer { try? FileManager.default.removeItem(at: url) }
        return try await transcribe(file: url)
    }

    func transcribe(file: URL) async throws -> Transcription {
        guard state == .ready, let locale else { throw TranscriberError.notReady }
        let start = Date()
        let text: String
        if #available(macOS 26, *) {
            text = try await Self.transcribeModern(file: file, locale: locale)
        } else {
            text = try await Self.transcribeLegacy(file: file, locale: locale)
        }
        let duration = (try? AVAudioFile(forReading: file).duration) ?? 0
        return Transcription(text: text,
                             confidence: 1,
                             audioDuration: duration,
                             processingTime: Date().timeIntervalSince(start))
    }

    // Same windowed re-decode strategy as the primary engine — and the bounded
    // window matters twice here, because every pass also rewrites its audio to
    // a temp WAV before decoding.
    func makeStreamingTranscription() -> StreamingTranscription? {
        guard state == .ready else { return nil }
        return RedecodeStreamingTranscription { [weak self] samples in
            guard let self else { throw TranscriberError.notReady }
            return try await self.transcribe(samples: samples).text
        }
    }

    // MARK: engines

    @available(macOS 26, *)
    private static func transcribeModern(file: URL, locale: Locale) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var parts: [String] = []
            for try await result in transcriber.results where result.isFinal {
                parts.append(String(result.text.characters))
            }
            return parts.joined(separator: " ")
        }
        let audio = try AVAudioFile(forReading: file)
        if let last = try await analyzer.analyzeSequence(from: audio) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }

    private static func transcribeLegacy(file: URL, locale: Locale) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw AppleSpeechError.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true   // the privacy promise is absolute
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        return try await withCheckedThrowingContinuation { cont in
            var done = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let result, result.isFinal {
                    done = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    done = true
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func writeTempWav(samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-\(UUID().uuidString).wav")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw AppleSpeechError.unavailable
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }
}

enum AppleSpeechError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Basic dictation isn't available on this Mac right now."
        }
    }
}

private extension AVAudioFile {
    var duration: TimeInterval {
        Double(length) / fileFormat.sampleRate
    }
}
