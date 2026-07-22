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
    private(set) var state: TranscriberState = .modelMissing
    private var manager: AsrManager?
    private var models: AsrModels?
    private var decoderLayers: Int = 0
    private let prepareLock = AsyncSerialGate()

    init() {
        state = modelIsDownloaded ? .loading : .modelMissing
    }

    var modelIsDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3))
    }

    func prepare(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await prepareLock.run { [self] in
            if manager != nil { state = .ready; return }
            state = modelIsDownloaded ? .loading : .downloading(progress: 0)
            do {
                let models = try await AsrModels.downloadAndLoad(version: .v3) { progress in
                    onProgress(progress.fractionCompleted)
                }
                state = .loading
                let asr = AsrManager(config: .default)
                try await asr.loadModels(models)
                decoderLayers = await asr.decoderLayerCount
                manager = asr
                self.models = models
                state = .ready
            } catch {
                state = .failed(error.localizedDescription)
                throw error
            }
        }
    }

    func transcribe(samples: [Float]) async throws -> Transcription {
        guard let manager else { throw TranscriberError.notReady }
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        return Transcription(text: result.text,
                             confidence: result.confidence,
                             audioDuration: result.duration,
                             processingTime: result.processingTime)
    }

    func transcribe(file: URL) async throws -> Transcription {
        guard let manager else { throw TranscriberError.notReady }
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(file, decoderState: &decoderState)
        return Transcription(text: result.text,
                             confidence: result.confidence,
                             audioDuration: result.duration,
                             processingTime: result.processingTime)
    }

    // Live sessions decode with the same batch pipeline as transcribe(samples:),
    // so no extra model state is needed — just a decode function.
    func makeStreamingTranscription() -> StreamingTranscription? {
        guard manager != nil, state == .ready else { return nil }
        return ParakeetStreamingTranscription { [weak self] samples in
            guard let self else { throw TranscriberError.notReady }
            return try await self.transcribe(samples: samples).text
        }
    }
}

// Live transcription by whole-buffer re-decode: every ~1 s, run the SAME batch
// transcription the commit path uses over ALL audio captured so far (fresh
// decoder state each pass; >15 s audio auto-chunks internally exactly like a
// committed dictation would). Each update is therefore a full-context best
// hypothesis — later speech genuinely revises earlier words, and the preview
// converges on the batch result by construction.
//
// Chosen over the SDK's SlidingWindowAsrManager, whose small-chunk streaming
// path proved fragile (cross-window token dedup drops words; the decoder's
// time index can run past short windows and starve, silently losing the tail).
// Re-decode costs one inference per tick (~0.1 s on Apple silicon for ≤15 s of
// audio) which comfortably outruns the update cadence.
final class ParakeetStreamingTranscription: StreamingTranscription, @unchecked Sendable {
    // New audio required before another decode is worth it.
    private static let minNewSamples = 4_800          // 0.3 s, also the model's floor
    private static let tickInterval: UInt64 = 250_000_000   // 0.25 s poll

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
            while let self {
                let (snapshot, done) = self.snapshotBuffer()
                if snapshot.count - decodedCount >= Self.minNewSamples,
                   snapshot.count >= Self.minNewSamples {
                    decodedCount = snapshot.count
                    if let text = try? await self.decode(snapshot) {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            self.updateContinuation.yield(LiveTranscript(confirmed: "", volatile: trimmed))
                        }
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
        let text = samples.count >= Self.minNewSamples ? try await decode(samples) : ""
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
