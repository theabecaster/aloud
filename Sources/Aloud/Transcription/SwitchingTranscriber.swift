import Foundation

// Composite Transcriber: the primary engine (downloaded voice model) plus an
// optional system fallback for the window before the model is ready. Routing
// is decided per call, so the moment the primary reaches .ready every new
// dictation silently uses it. A live session that started on the fallback may
// settle its final pass on the freshly-ready primary — that's the same
// preview-vs-final divergence the live-typing contract already allows.
//
// The fallback only participates after activate(), an explicit opt-in:
// onboarding's "skip" button, or a quiet re-activation on later launches
// (which never triggers a permission prompt).
final class SwitchingTranscriber: Transcriber {
    let primary: Transcriber
    let fallback: Transcriber?
    private(set) var fallbackActive = false

    init(primary: Transcriber, fallback: Transcriber?) {
        self.primary = primary
        self.fallback = fallback
    }

    // Effective state: ready when either usable engine is. While neither is
    // ready, mirror the primary so download progress reaches the UI.
    var state: TranscriberState {
        if primary.state == .ready { return .ready }
        if usingFallback { return .ready }
        return primary.state
    }

    // The primary's own state, regardless of fallback — drives "still
    // downloading in the background" UI.
    var primaryState: TranscriberState { primary.state }

    var usingFallback: Bool {
        primary.state != .ready && fallbackActive && fallback?.state == .ready
    }

    var modelIsDownloaded: Bool { primary.modelIsDownloaded }

    // prepare() drives the primary (download + warm). The fallback has its own
    // explicit activation path so permission prompts can't appear unbidden.
    func prepare(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await primary.prepare(onProgress: onProgress)
    }

    // Bring the fallback up. Returns false when it can't run here (no engine,
    // permission denied, assets unavailable offline).
    func activateFallback() async -> Bool {
        guard let fallback else { return false }
        if fallback.state == .ready { fallbackActive = true; return true }
        do {
            try await fallback.prepare { _ in }
            fallbackActive = true
            return true
        } catch {
            return false
        }
    }

    private var engine: Transcriber {
        if primary.state == .ready { return primary }
        if usingFallback, let fallback { return fallback }
        return primary
    }

    func transcribe(samples: [Float]) async throws -> Transcription {
        try await engine.transcribe(samples: samples)
    }

    func transcribe(file: URL) async throws -> Transcription {
        try await engine.transcribe(file: file)
    }

    func makeStreamingTranscription() -> StreamingTranscription? {
        engine.makeStreamingTranscription()
    }
}
