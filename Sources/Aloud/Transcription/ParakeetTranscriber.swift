import Foundation
import FluidAudio

// FluidAudio-backed Transcriber (Parakeet TDT v3 CoreML on the Neural Engine).
//
// Facts this file depends on (verified against FluidAudio 0.15.5):
// - AsrModels.downloadAndLoad(version: .v3, progressHandler:) downloads ~480 MB
//   to ~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml/
//   and compiles on first load (~15 s cold, ~2 s warm).
// - AsrManager is an actor; transcribe requires an inout TdtDecoderState created
//   from the manager's decoderLayerCount. Audio must be 16 kHz mono Float32,
//   ≥ 0.3 s. Longer audio is auto-chunked internally.
final class ParakeetTranscriber: Transcriber {
    static let sampleRate = AudioRecorder.targetSampleRate
    private(set) var state: TranscriberState = .modelMissing
    private var manager: AsrManager?
    private var decoderLayers: Int = 0
    private let prepareLock = AsyncSerialGate()
    // Decode-time biasing toward the user's Vocabulary replacements. Loads its
    // own auxiliary models lazily and only when replacements exist.
    private let booster = VocabularyBooster()

    init() {
        state = modelIsDownloaded ? .loading : .modelMissing
    }

    var modelIsDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3))
    }

    // With exactly one declared language, the decoder can skip candidate
    // tokens from other scripts (SDK script filtering) — a mild guard against
    // drifting into the wrong alphabet. Several declared languages (or one
    // the SDK's filter doesn't know) mean full auto-detection, the default.
    private var languageHint: Language? {
        let declared = SettingsStore.shared.declaredLanguages
        guard declared.count == 1, let code = declared.first else { return nil }
        return Language(rawValue: code)
    }

    func prepare(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await prepareLock.run { [self] in
            if manager != nil { state = .ready; return }
            let needsDownload = !modelIsDownloaded
            state = needsDownload ? .downloading(progress: 0) : .loading
            do {
                // The SDK fires the progress handler even when the files are
                // already on disk (load/verify stages); surfacing those as
                // download percentages makes every launch flash a phantom
                // progress badge. Only forward when a download is happening.
                let models = try await AsrModels.downloadAndLoad(version: .v3) { progress in
                    if needsDownload { onProgress(progress.fractionCompleted) }
                }
                state = .loading
                let asr = AsrManager(config: .default)
                try await asr.loadModels(models)
                decoderLayers = await asr.decoderLayerCount
                manager = asr
                state = .ready
                // Warm vocabulary biasing off the critical path so the first
                // dictation can already benefit from it.
                let booster = booster
                Task.detached(priority: .utility) {
                    await booster.warm(terms: SettingsStore.shared.replacements)
                }
            } catch {
                state = .failed(error.localizedDescription)
                throw error
            }
        }
    }

    // The model works on a fixed fifteen-second window and is told how much of
    // it is real audio; the decoder then walks exactly that many frames. That
    // bound turns out to change the answer: the same speech, decoded at
    // different lengths, comes back different — and sometimes the *opening
    // sentence is missing*. Measured on one recording: 12 s → 26 words, 13 s →
    // 26, **14 s → 6**, 15 s → 36, and padding a 12 s clip with silence to
    // 12.16 s dropped its first sentence. Nothing about the audio changed, only
    // how much of the window the decoder was allowed to see.
    //
    // Filling the window makes every dictation take the same path through the
    // decoder, and the results stop moving: all the failing lengths above come
    // back complete and identical. Clean fixtures are unchanged or slightly
    // better punctuated — the model gets the context it was trained on — and
    // nothing is invented in the silence. It costs nothing: the engine already
    // pads to this length internally, so the encoder was always running on a
    // full window regardless.
    static func decodeWindow(_ samples: [Float]) -> [Float] {
        guard samples.count < ASRConstants.maxModelSamples else { return samples }
        return samples + [Float](repeating: 0,
                                 count: ASRConstants.maxModelSamples - samples.count)
    }

    func transcribe(samples: [Float]) async throws -> Transcription {
        guard let manager else { throw TranscriberError.notReady }
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        let spokenSeconds = Double(samples.count) / Self.sampleRate
        let result = try await manager.transcribe(Self.decodeWindow(samples),
                                                  decoderState: &decoderState,
                                                  language: languageHint)
        // Vocabulary biasing runs on the dictation (samples) path only: once
        // per committed dictation, and never on transcribe(file:) — that's the
        // CLI/eval surface, which must stay pure engine output the same way
        // the text polisher never touches it.
        var text = result.text
        if let timings = result.tokenTimings,
           let boosted = await booster.rescore(text: text, tokenTimings: timings,
                                               samples: samples,
                                               terms: SettingsStore.shared.replacements) {
            text = boosted
        }
        return Transcription(text: text,
                             confidence: result.confidence,
                             // The engine now reports the padded window; what
                             // history and the stats care about is how long
                             // the person actually spoke.
                             audioDuration: spokenSeconds,
                             processingTime: result.processingTime)
    }

    func transcribe(file: URL) async throws -> Transcription {
        guard let manager else { throw TranscriberError.notReady }
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(file, decoderState: &decoderState,
                                                  language: languageHint)
        return Transcription(text: result.text,
                             confidence: result.confidence,
                             audioDuration: result.duration,
                             processingTime: result.processingTime)
    }

    // Live sessions decode with the same batch pipeline as transcribe(samples:),
    // so no extra model state is needed — just a decode function. Previews
    // skip vocabulary biasing (it would add a CTC inference every tick); the
    // final commit goes through transcribe(samples:) and applies it once —
    // preview-vs-final divergence the live-typing contract already allows.
    func makeStreamingTranscription() -> StreamingTranscription? {
        guard manager != nil, state == .ready else { return nil }
        return RedecodeStreamingTranscription { [weak self] samples in
            guard let self, let manager = self.manager else { throw TranscriberError.notReady }
            var decoderState = TdtDecoderState.make(decoderLayers: self.decoderLayers)
            return try await manager.transcribe(Self.decodeWindow(samples),
                                                decoderState: &decoderState,
                                                language: self.languageHint).text
        }
    }
}

// Live transcription by whole-buffer re-decode: a few times a second, run the
// SAME batch transcription the commit path uses over ALL audio captured so far
// (fresh decoder state each pass; >15 s audio auto-chunks internally exactly
// like a committed dictation would). Each update is therefore a full-context
// best hypothesis — later speech genuinely revises earlier words, and the
// preview converges on the batch result by construction. Those revisions are
// not published raw: StableTranscript holds each word back until two
// consecutive decodes agree on it, so what reaches the screen only grows.
// Engine-agnostic: any Transcriber can stream this way by handing over its
// decode function.
//
// Chosen over the SDK's SlidingWindowAsrManager, whose small-chunk streaming
// path proved fragile (cross-window token dedup drops words; the decoder's
// time index can run past short windows and starve, silently losing the tail).
// Re-decode costs one inference per tick (~0.1 s on Apple silicon for ≤15 s of
// audio) which comfortably outruns the update cadence.
final class RedecodeStreamingTranscription: StreamingTranscription, @unchecked Sendable {
    // The model's floor: shorter audio than this can't be decoded at all.
    private static let minSamples = 4_800             // 0.3 s
    // New audio required before another decode is worth it. Below the floor on
    // purpose — a word is only released once two decodes agree on it, so a
    // tighter cadence is what keeps that confirmation feeling immediate. The
    // pump awaits each decode, so it can never outrun the hardware.
    private static let minNewSamples = 3_200          // 0.2 s
    private static let tickInterval: UInt64 = 150_000_000   // 0.15 s poll

    private let decode: @Sendable ([Float]) async throws -> String
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var finished = false
    private let updateStream: AsyncStream<LiveTranscript>
    private let updateContinuation: AsyncStream<LiveTranscript>.Continuation
    private var pumpTask: Task<Void, Never>?
    private let sessionStart = Date()

    init(decode: @escaping @Sendable ([Float]) async throws -> String) {
        self.decode = decode
        (updateStream, updateContinuation) = AsyncStream.makeStream(of: LiveTranscript.self)
        pumpTask = Task { [weak self] in
            var decodedCount = 0
            var stable = StableTranscript()
            while let self {
                let (snapshot, done) = self.snapshotBuffer()
                if snapshot.count >= Self.minSamples,
                   snapshot.count - decodedCount >= Self.minNewSamples {
                    decodedCount = snapshot.count
                    // A preview that is nothing but a filler is withheld: two
                    // consecutive decodes of the same room tone agree on
                    // "Yeah." as readily as on a real word, so without this the
                    // preview types a phantom and the commit has to take it
                    // back. No confidence to weigh here (a decode pass returns
                    // text only), and none is needed — either speech follows
                    // and the filler stops being the whole transcript, or the
                    // commit re-decodes and rules on it with PhantomFilter.
                    if let text = try? await self.decode(snapshot),
                       !PhantomFilter.isFillerOnly(text),
                       let confirmed = stable.accept(text), !confirmed.isEmpty {
                        self.updateContinuation.yield(LiveTranscript(confirmed: confirmed, volatile: ""))
                    }
                }
                if done { break }
                try? await Task.sleep(nanoseconds: Self.tickInterval)
                if Task.isCancelled { break }
            }
            self?.updateContinuation.finish()
        }
    }

    func append(samples: [Float]) {
        lock.lock()
        buffer.append(contentsOf: samples)
        lock.unlock()
    }

    var updates: AsyncStream<LiveTranscript> { updateStream }

    private func snapshotBuffer() -> ([Float], Bool) {
        lock.lock(); defer { lock.unlock() }
        return (buffer, finished)
    }

    private func markFinished() {
        lock.lock(); finished = true; lock.unlock()
    }

    func finish() async throws -> Transcription {
        markFinished()
        await pumpTask?.value
        let (samples, _) = snapshotBuffer()
        var text = samples.count >= Self.minSamples ? try await decode(samples) : ""
        // Same rule the preview stream runs on, for the same reason — this is
        // the end of that stream, not the committed dictation (which goes
        // through transcribe(samples:) and gets the confidence-aware check).
        if PhantomFilter.isFillerOnly(text) { text = "" }
        return Transcription(text: text,
                             confidence: 1,
                             audioDuration: Double(samples.count) / 16_000,
                             processingTime: Date().timeIntervalSince(sessionStart))
    }

    func cancel() async {
        markFinished()
        pumpTask?.cancel()
        updateContinuation.finish()
    }
}

enum TranscriberError: LocalizedError {
    case notReady
    var errorDescription: String? {
        switch self {
        case .notReady: return "The voice model isn't ready yet."
        }
    }
}

// Serializes async prepare() calls so concurrent callers share one download.
actor AsyncSerialGate {
    private var inFlight: Task<Void, Error>?

    func run(_ body: @escaping () async throws -> Void) async throws {
        if let existing = inFlight {
            try await existing.value
            return
        }
        let task = Task { try await body() }
        inFlight = task
        defer { inFlight = nil }
        try await task.value
    }
}
