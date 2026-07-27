import FluidAudio
import Foundation

// Live "is anyone actually talking?" for the current recording session.
//
// Audio arrives on the tap thread in whatever sizes CoreAudio hands us; the
// detector wants exactly 256 ms frames and carries state between them, so this
// buffers and feeds it from a background pump. Callers only ever read
// `secondsSinceSpeech`, which is cheap and lock-guarded.
//
// The point of it: a level threshold answers "is the room loud", not "is
// someone speaking", and in the rooms Aloud is trying to work in those two
// questions have opposite answers. Anything that needs to know whether the
// user has stopped talking has to ask a model, not the meter.
final class SpeechActivity: @unchecked Sendable {
    // A frame counts as speech at or above this probability. The detector's
    // own default; deliberately not tunable — this feeds a 30-second reminder,
    // not a decision about what gets typed.
    private static let speechProbability: Float = 0.5

    private let lock = NSLock()
    private var pending: [Float] = []
    private var lastSpeechUptime: TimeInterval?
    private var startUptime: TimeInterval?
    private var running = false
    private var pump: Task<Void, Never>?

    // Seconds since speech was last heard, or since the session started if it
    // never has been. nil when the detector isn't available (models not
    // downloaded yet, or load failed) — callers fall back to their own
    // heuristic rather than pretending silence.
    var secondsSinceSpeech: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard running, let reference = lastSpeechUptime ?? startUptime else { return nil }
        return ProcessInfo.processInfo.systemUptime - reference
    }

    // Begin a session. No-op (and `secondsSinceSpeech` stays nil) when the
    // detector isn't loaded, so this is always safe to call.
    func start() {
        stop()
        lock.lock()
        pending = []
        lastSpeechUptime = nil
        startUptime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        pump = Task { [weak self] in
            guard let detector = await VoiceModels.shared.speechDetector() else { return }
            await self?.run(detector: detector)
        }
    }

    func stop() {
        pump?.cancel()
        pump = nil
        lock.lock()
        running = false
        pending = []
        lock.unlock()
    }

    // Safe to call from the audio tap thread.
    func append(samples: [Float]) {
        lock.lock()
        pending.append(contentsOf: samples)
        lock.unlock()
    }

    private func run(detector: VadManager) async {
        markRunning()
        var state = await detector.makeStreamState()
        while !Task.isCancelled {
            guard let frame = nextFrame() else {
                try? await Task.sleep(nanoseconds: 60_000_000)   // 60 ms
                continue
            }
            guard let result = try? await detector.processStreamingChunk(frame, state: state) else { continue }
            state = result.state
            if result.probability >= Self.speechProbability { markSpeech() }
        }
    }

    // Both of these are the same lock the tap thread and the pill use; they're
    // separate synchronous methods because holding a lock across a suspension
    // point is exactly what Swift's concurrency checking is right to reject.
    private func markRunning() {
        lock.lock(); defer { lock.unlock() }
        running = true
    }

    private func markSpeech() {
        lock.lock(); defer { lock.unlock() }
        lastSpeechUptime = ProcessInfo.processInfo.systemUptime
    }

    // One detector-sized frame, or nil when not enough audio has arrived yet.
    // A backlog is dropped rather than queued: this answers a question about
    // *now*, and catching up on stale audio would only delay the answer.
    private func nextFrame() -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        let size = VadManager.chunkSize
        guard pending.count >= size else { return nil }
        let maxBacklog = size * 8   // ~2 s
        if pending.count > maxBacklog {
            pending.removeFirst(pending.count - maxBacklog)
        }
        let frame = Array(pending.prefix(size))
        pending.removeFirst(size)
        return frame
    }
}
