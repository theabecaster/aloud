import Foundation

// Engine-agnostic transcription interface. The concrete engine (currently
// FluidAudio + a CoreML speech model) is an implementation detail — nothing
// outside Transcription/ may reference it, and the UI never names it.

struct Transcription {
    let text: String
    let confidence: Float        // 0…1 aggregate
    let audioDuration: TimeInterval
    let processingTime: TimeInterval
}

enum TranscriberState: Equatable {
    case modelMissing                  // needs the one-time download
    case downloading(progress: Double) // 0…1
    case loading                       // CoreML warm-up / first-run compile
    case ready
    case failed(String)
}

protocol Transcriber: AnyObject {
    var state: TranscriberState { get }
    // Download (if needed) + load + warm the model. Safe to call repeatedly.
    func prepare(onProgress: @escaping @Sendable (Double) -> Void) async throws
    // 16 kHz mono Float32 samples → text. Requires prepare() to have succeeded.
    func transcribe(samples: [Float]) async throws -> Transcription
    func transcribe(file: URL) async throws -> Transcription
    // True when the model files exist locally (no network needed to prepare).
    var modelIsDownloaded: Bool { get }
}
