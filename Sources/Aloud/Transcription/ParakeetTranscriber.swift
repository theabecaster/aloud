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
    // Read on the main actor, because that is the only place it is written.
    //
    // `SettingsStore` is a plain ObservableObject whose arrays are mutated from
    // the main actor — the Vocabulary pane, an accepted correction — while this
    // is a nonisolated `async` method running on the cooperative pool. Reading
    // an Array while another thread reassigns it is a torn read or an
    // over-release of the old buffer: the once-a-month crash with no repro, in
    // a process that stays up for weeks.
    private var languageHint: Language? {
        get async {
            let declared = await MainActor.run { SettingsStore.shared.declaredLanguages }
            guard declared.count == 1, let code = declared.first else { return nil }
            return Language(rawValue: code)
        }
    }

    // Same reasoning: snapshot the terms on the main actor before handing them
    // to anything running off it.
    private static var replacements: [Replacement] {
        get async { await MainActor.run { SettingsStore.shared.replacements } }
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
                    let terms = await Self.replacements
                    await booster.warm(terms: terms)
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
                                                  language: await languageHint)
        // Vocabulary biasing runs on the dictation (samples) path only: once
        // per committed dictation, and never on transcribe(file:) — that's the
        // CLI/eval surface, which must stay pure engine output the same way
        // the text polisher never touches it.
        var text = result.text
        if let timings = result.tokenTimings,
           let boosted = await booster.rescore(text: text, tokenTimings: timings,
                                               samples: samples,
                                               terms: await Self.replacements) {
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
                                                  language: await languageHint)
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
                                                language: await self.languageHint).text
        }
    }
}

// Live transcription by re-decode: a few times a second, run the SAME batch
// transcription the commit path uses over the current live window (fresh
// decoder state each pass). Each update is a full-context hypothesis for that
// window — later speech genuinely revises earlier words in it. Revisions are
// not published raw: StableTranscript holds each word back until two
// consecutive decodes agree on it, so what reaches the screen grows steadily.
// Engine-agnostic: any Transcriber can stream this way by handing over its
// decode function.
//
// The window is bounded by ChunkedLivePreview: once it fills (~11–14.5 s) its
// text freezes and the window restarts, so a tick costs one model-window
// inference (~0.1 s on Apple silicon) no matter how long the session runs —
// it never decodes the whole recording. The commit path still does, once, so
// the final text keeps full context.
//
// Chosen over the SDK's SlidingWindowAsrManager, whose small-chunk streaming
// path proved fragile (cross-window token dedup drops words; the decoder's
// time index can run past short windows and starve, silently losing the tail).
final class RedecodeStreamingTranscription: StreamingTranscription, @unchecked Sendable {
    // The model's floor: shorter audio than this can't be decoded at all.
    private static let minSamples = 4_800             // 0.3 s
    // New audio required before another decode is worth it. Below the floor on
    // purpose — a word is only released once two decodes agree on it, so a
    // tighter cadence is what keeps that confirmation feeling immediate. The
    // pump awaits each decode, so it can never outrun the hardware.
    private static let minNewSamples = 3_200          // 0.2 s
    private static let tickInterval: UInt64 = 150_000_000   // 0.15 s poll
    // ALOUD_LIVE_TIMING=1 prints each tick's window size and decode time to
    // stderr — how the flat-per-tick-cost claim gets measured, nothing more.
    private static let timingEnabled =
        ProcessInfo.processInfo.environment["ALOUD_LIVE_TIMING"] == "1"

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
            var preview = ChunkedLivePreview()
            while let self {
                let (window, total, done) = self.snapshotWindow(from: preview.windowStart)
                let windowEnd = preview.windowStart + window.count
                if window.count >= Self.minSamples,
                   total - decodedCount >= Self.minNewSamples {
                    decodedCount = windowEnd
                    // Filler-only windows are withheld inside the preview: two
                    // consecutive decodes of the same room tone agree on
                    // "Yeah." as readily as on a real word, so without this the
                    // preview types a phantom and the commit has to take it
                    // back. No confidence to weigh here (a decode pass returns
                    // text only), and none is needed — either speech follows
                    // and the filler stops being the whole window, or the
                    // commit re-decodes and rules on it with PhantomFilter.
                    let started = Self.timingEnabled ? Date() : nil
                    let text = try? await self.decode(window)
                    if let started {
                        let line = String(format: "tick: buffered %.1fs window %.1fs decode %.0fms\n",
                                          Double(total) / 16_000, Double(window.count) / 16_000,
                                          -started.timeIntervalSinceNow * 1_000)
                        FileHandle.standardError.write(Data(line.utf8))
                    }
                    if let text,
                       let display = preview.accept(text, decodedEnd: windowEnd,
                                                    tailQuiet: ChunkedLivePreview.tailIsQuiet(window)) {
                        self.updateContinuation.yield(LiveTranscript(confirmed: display, volatile: ""))
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

    // The live window plus where the buffer ends — one lock so the two agree.
    // The window is clipped to the chunk cap: when appends have outrun decodes
    // (a file fed faster than realtime, a slow decode moment), each tick still
    // decodes one bounded chunk and the cap-roll walks the backlog.
    private func snapshotWindow(from start: Int) -> ([Float], Int, Bool) {
        lock.lock(); defer { lock.unlock() }
        let end = min(buffer.count, start + ChunkedLivePreview.hardCapSamples)
        return (Array(buffer[start..<end]), buffer.count, finished)
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
