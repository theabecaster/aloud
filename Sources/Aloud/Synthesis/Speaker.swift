import Foundation

// Engine-agnostic speech synthesis, mirroring Transcriber on the way in.
// The concrete engine is an implementation detail — nothing outside
// Synthesis/ may reference it, and the UI never names it. Users pick between
// "System voice" and "Enhanced voice", never between model names.

struct Speech {
    let samples: [Float]        // mono Float32
    let sampleRate: Int
    let synthesisTime: TimeInterval

    var duration: TimeInterval {
        sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
    }

    // How much faster than realtime the synthesis ran. Below 1 means audio is
    // produced faster than it plays, which is what a responsive `speak` needs.
    var realtimeFactor: Double {
        duration > 0 ? synthesisTime / duration : 0
    }
}

enum SpeakerState: Equatable {
    case modelMissing                  // needs the one-time download
    case downloading(progress: Double) // 0…1
    case loading
    case ready
    case failed(String)
}

enum SpeakerError: LocalizedError {
    case notReady
    case emptyText
    case synthesisFailed(String)
    case playbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .notReady: return "the voice isn't ready yet"
        case .emptyText: return "nothing to say"
        case .synthesisFailed(let why): return "synthesis failed: \(why)"
        case .playbackFailed(let why): return "playback failed: \(why)"
        }
    }
}

enum SpeakerFactory {
    // The enhanced voice only when its assets are already on disk. Everything
    // else gets the system voice, which is why `speak` is never broken — the
    // download is an upgrade, not a prerequisite, and nothing has to block on
    // it. Fetching those assets is the caller's business, not the factory's.
    static func make() -> Speaker {
        let enhanced = NeuralSpeaker()
        return enhanced.modelIsDownloaded ? enhanced : SystemSpeaker()
    }
}

protocol Speaker: AnyObject {
    var state: SpeakerState { get }
    // True when the voice can be used with no network. Always true for the
    // system voice; asset-dependent for the enhanced one.
    var modelIsDownloaded: Bool { get }
    // Download (if needed) + load. Safe to call repeatedly.
    func prepare() async throws
    // Text → samples, no playback. The headless path: CLI verbs and the
    // selftest verify synthesis without anyone having to listen.
    func synthesize(_ text: String) async throws -> Speech
    // Text → audible speech. Returns when playback finishes.
    func speak(_ text: String) async throws
    // Cut playback short. Safe to call when nothing is playing.
    func stop()
}
