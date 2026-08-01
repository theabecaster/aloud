import AVFoundation
import FluidAudio
import Foundation

// The enhanced voice: on-device CoreML synthesis, downloaded once.
//
// `kokoro` is the default, measured rather than assumed (docs §5a): 191 MB on
// disk against pocket's 974 MB, for slightly better throughput (RTF 0.208 vs
// 0.239) and a six-times faster warm load. `pocket` stays wired up because it
// is the only streaming-capable backend here, which is what a future `speak`
// that reads long text would want — and because keeping the comparison
// runnable is cheaper than rebuilding it later.
enum NeuralEngine: String, CaseIterable {
    case kokoro     // 7-stage chain with per-stage ANE/GPU placement, 24 kHz
    case pocket     // autoregressive flow-matching, streaming-capable, 24 kHz

    // Where FluidAudio caches this engine's models, so readiness can be
    // checked without loading anything. Mirrors ModelNames — if the SDK
    // moves these, `modelIsDownloaded` degrades to "not downloaded" and we
    // re-fetch, which is wasteful but never wrong.
    var cacheSubpath: String {
        switch self {
        case .kokoro: return "kokoro-82m-coreml/ANE"
        case .pocket: return "pocket-tts-coreml"
        }
    }
}

final class NeuralSpeaker: Speaker {
    private let engine: NeuralEngine
    private let player = SpeechPlayer()
    private var kokoro: KokoroAneManager?
    private var pocket: PocketTtsManager?
    private let loadGate = AsyncGate()

    private(set) var state: SpeakerState

    init(engine: NeuralEngine = .kokoro) {
        self.engine = engine
        self.state = .modelMissing
    }

    var modelIsDownloaded: Bool {
        guard let base = try? TtsCacheDirectory.ensure() else { return false }
        let dir = base.appendingPathComponent("Models").appendingPathComponent(engine.cacheSubpath)
        let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        return !(contents ?? []).isEmpty
    }

    // Downloads on first call. FluidAudio's TTS managers expose no progress
    // callback, unlike the speech model's — which is why the plan fetches this
    // quietly in the background rather than putting it behind a progress bar
    // the user is made to watch.
    func prepare() async throws {
        try await loadGate.run { [self] in
            if kokoro != nil || pocket != nil { state = .ready; return }
            state = modelIsDownloaded ? .loading : .downloading(progress: 0)
            do {
                switch engine {
                case .kokoro:
                    let manager = KokoroAneManager(variant: .english)
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
        case .kokoro:
            guard let kokoro else { throw SpeakerError.notReady }
            let result = try await kokoro.synthesizeDetailed(text: trimmed)
            return Speech(samples: result.samples, sampleRate: result.sampleRate,
                          synthesisTime: Date().timeIntervalSince(started))
        case .pocket:
            guard let pocket else { throw SpeakerError.notReady }
            let wav = try await pocket.synthesize(text: trimmed)
            let (samples, rate) = try Self.decodeWAV(wav)
            return Speech(samples: samples, sampleRate: rate,
                          synthesisTime: Date().timeIntervalSince(started))
        }
    }

    func speak(_ text: String) async throws {
        try await player.play(try await synthesize(text))
    }

    func stop() { player.stop() }

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
