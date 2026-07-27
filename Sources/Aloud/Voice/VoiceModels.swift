import CoreML
import FluidAudio
import Foundation

// The small CoreML model behind speech detection: is anyone talking, as
// opposed to what they said.
//
// It lives here rather than inside Transcription/ on purpose — this is not the
// speech engine, and nothing in this file affects what gets typed. Its one
// consumer is SpeechActivity, which decides whether a hands-free session has
// actually heard anyone.
//
// About a megabyte, next to ~461 MB for the speech model. It downloads as part
// of that same setup so the user sees one progress bar, and a failure here is
// swallowed: dictation must never be held up by a model dictation doesn't use.
actor VoiceModels {
    static let shared = VoiceModels()

    // Share of the setup progress bar this model is given — roughly its share
    // of the bytes. Small enough to be a rounding error, kept explicit so the
    // bar still moves smoothly and never goes backwards.
    static let downloadShare = 0.01

    private var vad: VadManager?
    private var loadFailed = false
    private var preparing: Task<Void, Error>?

    // True when the model is already on disk, so preparing needs no network.
    // Cheap enough to call from anywhere (a file-existence check).
    nonisolated static var isDownloaded: Bool {
        let vadFile = MLModelConfigurationUtils.defaultModelsDirectory(for: .vad)
            .appendingPathComponent(ModelNames.VAD.sileroVadFile)
        return FileManager.default.fileExists(atPath: vadFile.path)
    }

    // Fetch and load the detector. `onProgress` runs 0 → 1. Safe to call
    // repeatedly; concurrent callers share one run.
    func prepare(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if let existing = preparing { try await existing.value; return }
        let task = Task<Void, Error> { [self] in
            do {
                if vad == nil {
                    vad = try await VadManager(config: .default) { progress in
                        onProgress(progress.fractionCompleted)
                    }
                }
                onProgress(1)
            } catch {
                loadFailed = true
                throw error
            }
        }
        preparing = task
        defer { preparing = nil }
        try await task.value
    }

    // The speech detector, or nil when it isn't loaded. Never downloads —
    // callers on the audio path must not stall on the network.
    func speechDetector() -> VadManager? { vad }

    // Where speech starts and stops, in seconds. Diagnostic only
    // (--speech-check); the live path streams through `speechDetector`.
    func speechRanges(for samples: [Float]) async throws -> [(start: Double, end: Double)] {
        guard let vad else { throw VoiceModelsError.notReady }
        return try await vad.segmentSpeech(samples).map { (start: $0.startTime, end: $0.endTime) }
    }

    var isReady: Bool { vad != nil }
    var didFail: Bool { loadFailed }
}

enum VoiceModelsError: LocalizedError {
    case notReady
    var errorDescription: String? {
        switch self {
        case .notReady: return "The speech detector isn’t loaded."
        }
    }
}
