import AVFoundation
import FluidAudio
import Foundation

// The enhanced voice: on-device CoreML synthesis, downloaded once.
//
// `supertonic` is the default. It replaced `kokoro` for one reason: kokoro's
// English bundle ships exactly one voice pack (`af_heart`, female), so half of
// "pick a voice gender" had nowhere to go and the male side was stuck on
// whatever compact voice macOS happened to have. Supertonic-3 carries five
// male and five female preset styles behind one ~200 MB download — the same
// ballpark as kokoro's 191 MB — at 44.1 kHz instead of 24, and speaks 31
// languages rather than English alone.
//
// `kokoro` and `pocket` stay wired up because keeping the comparison runnable
// is cheaper than rebuilding it later (docs §5a), and `pocket` is the only
// streaming-capable backend here, which is what a future `speak` that reads
// long text would want.
enum NeuralEngine: String, CaseIterable {
    case supertonic // 4-stage flow matching, 10 preset voices, 44.1 kHz
    case kokoro     // 7-stage chain with per-stage ANE/GPU placement, 24 kHz
    case pocket     // autoregressive flow-matching, streaming-capable, 24 kHz

    // Where FluidAudio caches this engine's models, so readiness can be
    // checked without loading anything. Mirrors ModelNames — if the SDK
    // moves these, `modelIsDownloaded` degrades to "not downloaded" and we
    // re-fetch, which is wasteful but never wrong.
    var cacheSubpath: String {
        switch self {
        case .supertonic: return "supertonic-3"
        case .kokoro: return "kokoro-82m-coreml/ANE"
        case .pocket: return "pocket-tts-coreml"
        }
    }

    /// Whether this engine can read that language at all. Kokoro's English
    /// bundle is English and nothing else; Supertonic-3 carries 31 languages,
    /// which is why a non-English user gets Aloud's own voice on the male side
    /// and the Mac's on the female one.
    func speaks(_ language: String) -> Bool {
        let code = String(language.prefix(2)).lowercased()
        switch self {
        case .supertonic: return Supertonic3Constants.availableLanguages.contains(code)
        case .kokoro, .pocket: return code == "en"
        }
    }

    /// Whether this engine's assets are already on disk, checked without
    /// loading anything. Mirrors ModelNames — if the SDK moves these, the
    /// answer degrades to "not downloaded" and we re-fetch, which is wasteful
    /// but never wrong.
    var isDownloaded: Bool {
        guard let base = try? TtsCacheDirectory.ensure() else { return false }
        let dir = base.appendingPathComponent("Models").appendingPathComponent(cacheSubpath)
        let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        return !(contents ?? []).isEmpty
    }
}

final class NeuralSpeaker: Speaker {
    private let engine: NeuralEngine
    private let player = SpeechPlayer()
    private var kokoro: KokoroAneManager?
    private var pocket: PocketTtsManager?
    private var supertonic: Supertonic3Manager?
    // Loaded alongside the models: on this engine a voice is a style tensor,
    // not a model, so switching voices costs a small JSON rather than a reload.
    private var supertonicStyle: Supertonic3VoiceStyle?
    private let styleName: String
    private let loadGate = AsyncGate()

    private(set) var state: SpeakerState

    // Handed to the engine per utterance, so the slider that sets it never
    // costs a model reload.
    var speed: Double = VoiceSpeed.normal

    // `style` names one of the engine's preset voices ("M1", "F2"). Ignored by
    // the engines that ship a single voice.
    init(engine: NeuralEngine = .supertonic, style: String = Supertonic3Voice.default.rawValue) {
        self.engine = engine
        self.styleName = style
        self.state = .modelMissing
    }

    var modelIsDownloaded: Bool { engine.isDownloaded }

    // Downloads on first call. FluidAudio's TTS managers expose no progress
    // callback, unlike the speech model's — which is why the plan fetches this
    // quietly in the background rather than putting it behind a progress bar
    // the user is made to watch.
    func prepare() async throws {
        try await loadGate.run { [self] in
            if kokoro != nil || pocket != nil || supertonic != nil { state = .ready; return }
            state = modelIsDownloaded ? .loading : .downloading(progress: 0)
            do {
                switch engine {
                case .supertonic:
                    let manager = Supertonic3Manager()
                    try await manager.initialize()
                    // The style is a preset shipped in the same repo, fetched
                    // on its own the first time a voice is used.
                    let voice = Supertonic3Voice(name: styleName) ?? .default
                    supertonicStyle = try await Supertonic3ResourceDownloader
                        .loadVoiceStyle(voice)
                    supertonic = manager
                case .kokoro:
                    // Off the ANE deliberately. On the default placement this
                    // engine synthesizes correctly exactly once per process:
                    // every later call fails inside `postAlbert` with a
                    // garbage tile shape out of BNNS ("reps[0] = -1287900868"),
                    // which is a first press that works and silence forever
                    // after — for the preview and for the second question an
                    // agent asks. Skipping the ANE avoids that path.
                    let manager = KokoroAneManager(variant: .english,
                                                   computeUnits: Self.kokoroPlacement)
                    try await manager.initialize()
                    kokoro = manager
                case .pocket:
                    let manager = PocketTtsManager()
                    try await manager.initialize()
                    pocket = manager
                }
                state = .ready
            } catch {
                state = .failed(error.localizedDescription)
                throw error
            }
        }
    }

    func synthesize(_ text: String) async throws -> Speech {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpeakerError.emptyText }
        try await prepare()

        let started = Date()
        switch engine {
        case .supertonic:
            guard let supertonic, let supertonicStyle else { throw SpeakerError.notReady }
            let result = try await supertonic.synthesize(
                text: trimmed,
                language: Self.supertonicLanguage,
                style: supertonicStyle,
                speed: Float(VoiceSpeed.clamped(speed)))
            return Speech(samples: result.samples,
                          sampleRate: Supertonic3Constants.sampleRate,
                          synthesisTime: Date().timeIntervalSince(started))
        case .kokoro:
            guard let kokoro else { throw SpeakerError.notReady }
            let result = try await kokoro.synthesizeDetailed(
                text: trimmed, speed: Float(VoiceSpeed.clamped(speed)))
            return Speech(samples: result.samples, sampleRate: result.sampleRate,
                          synthesisTime: Date().timeIntervalSince(started))
        case .pocket:
            guard let pocket else { throw SpeakerError.notReady }
            // No pace control on this backend — it is bench-only (see the
            // enum's note), so `speed` is simply not offered rather than
            // faked by resampling, which would move the pitch with it.
            let wav = try await pocket.synthesize(text: trimmed)
            let (samples, rate) = try Self.decodeWAV(wav)
            return Speech(samples: samples, sampleRate: rate,
                          synthesisTime: Date().timeIntervalSince(started))
        }
    }

    func speak(_ text: String) async throws {
        // Synthesis on this engine takes seconds, and `stop()` during it had
        // nothing to stop: the player was not playing yet, so `node.stop()` was
        // a no-op and nothing recorded that a stop had happened. The buffer
        // then played anyway — so ending an agent session took the pill down
        // and the Mac read out the question of the session the user had just
        // ended, a second later, with nothing on screen to explain it.
        let mine = beginUtterance()
        let speech = try await synthesize(text)
        // Thrown rather than returned. Returning normally told the caller the
        // sentence had been said: `AgentBridgeService.speak` saw a live lease
        // and answered `ok`, so the agent went straight on to `listen` and
        // opened the microphone on somebody who had been asked nothing.
        guard isCurrent(mine) else { throw SpeakerError.superseded }
        try await player.play(speech)
    }

    // Bumped by every new utterance and by every stop, so "is the utterance I
    // started still the one that is wanted" has an answer across an await.
    private let utteranceLock = NSLock()
    private var utteranceRun = 0

    private func beginUtterance() -> Int {
        utteranceLock.lock(); defer { utteranceLock.unlock() }
        utteranceRun += 1
        return utteranceRun
    }

    private func isCurrent(_ run: Int) -> Bool {
        utteranceLock.lock(); defer { utteranceLock.unlock() }
        return run == utteranceRun
    }

    private func cancelUtterance() {
        utteranceLock.lock(); defer { utteranceLock.unlock() }
        utteranceRun += 1
    }

    // Everything on its default placement except the one stage that cannot
    // survive a second call there. `postAlbert` on the Neural Engine
    // synthesizes correctly exactly once per process and then fails with a
    // garbage tile shape out of BNNS (`reps[0] = -1287900868`) — which reads,
    // from outside, as a voice that works once and is silent forever after:
    // the preview button after its first press, and the second question an
    // agent asks in a session. Only that stage moves, so the rest of the
    // chain keeps the Neural Engine and the cost is about a third of the
    // synthesis time rather than all of it.
    private static let kokoroPlacement = KokoroAneComputeUnits(postAlbert: .cpuAndGPU)

    // What language to read the text as. This engine speaks 31, so the answer
    // is the user's own rather than a hardcoded "en" — the same sentence read
    // as English and as German comes out differently, and an agent asking a
    // German user a question in German should not be read with English vowels.
    // Falls back to English for a language the engine does not have.
    private static var supertonicLanguage: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return Supertonic3Constants.availableLanguages.contains(code) ? code : "en"
    }

    func stop() {
        cancelUtterance()
        player.stop()
    }

    var currentLevel: Float { player.currentLevel }

    // False for the whole synthesis pass, which on this engine is the slow
    // half of `speak`.
    var isPlaying: Bool { player.isPlaying }

    // PocketTTS returns a WAV container rather than raw samples. Parsing it
    // here keeps `Speech` uniform across engines so the player and every
    // timing comparison stay engine-agnostic.
    private static func decodeWAV(_ data: Data) throws -> ([Float], Int) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-tts-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url)
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(file.length))
            else { throw SpeakerError.synthesisFailed("couldn't read synthesized audio") }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData else {
                throw SpeakerError.synthesisFailed("synthesized audio wasn't float PCM")
            }
            let samples = Array(UnsafeBufferPointer(start: channel[0],
                                                    count: Int(buffer.frameLength)))
            return (samples, Int(format.sampleRate))
        } catch let error as SpeakerError {
            throw error
        } catch {
            throw SpeakerError.synthesisFailed(error.localizedDescription)
        }
    }
}

// Serializes prepare() so concurrent callers share one download+load rather
// than racing two of them onto the Neural Engine.
private actor AsyncGate {
    private var running: Task<Void, Error>?

    func run(_ work: @escaping () async throws -> Void) async throws {
        if let running { return try await running.value }
        let task = Task { try await work() }
        running = task
        do {
            try await task.value
            running = nil
        } catch {
            running = nil
            throw error
        }
    }
}
