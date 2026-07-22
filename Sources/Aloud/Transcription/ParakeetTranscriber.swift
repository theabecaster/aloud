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
