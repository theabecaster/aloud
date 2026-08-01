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
//
// It has a second, permanent reason to run: `requiresFallback`, set when the
// user declares a language the primary engine doesn't cover. That one is not a
// window that closes — the download finishing changes nothing — which is why
// Settings words the two states differently even though the pill's "Basic" tag
// is the same in both.
final class SwitchingTranscriber: Transcriber {
    let primary: Transcriber
    let fallback: Transcriber?
    private(set) var fallbackActive = false

    // The user declared a language the primary engine cannot hear, so basic
    // dictation is the engine for good rather than only until the download
    // lands. Set from Settings → Dictation → Languages; the primary may be
    // perfectly ready and is still not used.
    var requiresFallback = false

    init(primary: Transcriber, fallback: Transcriber?) {
        self.primary = primary
        self.fallback = fallback
    }

    // Effective state: ready when either usable engine is. While neither is,
    // mirror the primary so download progress reaches the UI.
    //
    // Deliberately blind to `requiresFallback`: when the language asks for
    // basic dictation and this Mac can't provide it, the primary is what will
    // actually run, so reporting anything else would put "setup needed" in the
    // menu bar over dictation that works. Settings is where that language is
    // told it isn't being heard, because Settings is where it was chosen.
    var state: TranscriberState {
        if usingFallback { return .ready }
        if primary.state == .ready { return .ready }
        return primary.state
    }

    // The primary's own state, regardless of fallback — drives "still
    // downloading in the background" UI.
    var primaryState: TranscriberState { primary.state }

    var usingFallback: Bool {
        guard fallbackActive, fallback?.state == .ready else { return false }
        return requiresFallback || primary.state != .ready
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

    // usingFallback already answers "is the fallback both usable and wanted",
    // so it is asked first: past a language the primary can't hear, a ready
    // primary is the wrong engine, not the preferred one.
    private var engine: Transcriber {
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
