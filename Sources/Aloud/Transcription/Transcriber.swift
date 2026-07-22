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
    // One dictation's worth of live transcription, or nil when the engine
    // can't stream (callers fall back to batch transcribe). Requires .ready.
    func makeStreamingTranscription() -> StreamingTranscription?
}

extension Transcriber {
    func makeStreamingTranscription() -> StreamingTranscription? { nil }
}

// Snapshot of an in-progress transcript. `confirmed` is stable and only ever
// grows; `volatile` is the engine's current best guess for the most recent
// audio and may be rewritten by the next update.
struct LiveTranscript: Equatable, Sendable {
    var confirmed: String
    var volatile: String

    var full: String {
        switch (confirmed.isEmpty, volatile.isEmpty) {
        case (true, _): return volatile
        case (_, true): return confirmed
        default: return confirmed + " " + volatile
        }
    }
}

// A single live-transcription session: feed audio as it's captured, watch
// `updates`, then `finish()` for the final text (or `cancel()` to discard).
// `append` is safe to call from the audio tap thread.
protocol StreamingTranscription: AnyObject, Sendable {
    func append(samples: [Float])
    var updates: AsyncStream<LiveTranscript> { get }
    func finish() async throws -> Transcription
    func cancel() async
}
