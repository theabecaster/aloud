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
    //
    // `option` is the user's pick from VoiceCatalog; nil means they have not
    // made one and Aloud chooses. Either way the same rule holds: what comes
    // back can speak this instant. A user who picks the enhanced voice before
    // its download finishes is given a system voice for now rather than an
    // error — the choice is remembered in Settings and takes effect the moment
    // the assets land.
    static func make(_ option: VoiceOption? = nil,
                     speed: Double = VoiceSpeed.normal) -> Speaker {
        let speaker: Speaker
        switch option?.source {
        case .system(let identifier):
            speaker = SystemSpeaker(voiceIdentifier: identifier)
        case .enhanced(let engine, let style):
            let enhanced = NeuralSpeaker(engine: engine, style: style)
            // Stand in with the Mac's best voice on the *same* side — falling
            // back to "whatever this Mac speaks best" would answer a question
            // about a male voice in a female one, which reads as the setting
            // being ignored.
            speaker = enhanced.modelIsDownloaded
                ? enhanced
                : SystemSpeaker(voiceIdentifier: standIn(for: option?.gender))
        case nil:
            speaker = make(VoiceCatalog.resolved(gender: nil), speed: speed)
        }
        speaker.speed = VoiceSpeed.clamped(speed)
        return speaker
    }

    // The system voice that covers a side while Aloud's own is downloading.
    // nil means "whatever this Mac speaks best", which is what SystemSpeaker
    // does when it isn't given a voice.
    private static func standIn(for gender: VoiceGender?) -> String? {
        guard let gender, let option = VoiceCatalog.systemVoice(for: gender),
              case .system(let identifier) = option.source else { return nil }
        return identifier
    }
}

protocol Speaker: AnyObject {
    var state: SpeakerState { get }
    // How fast this voice talks, 1 being the pace it was built to run at.
    // Settable rather than fixed at construction because changing it must not
    // cost a reload: on the enhanced voice that would mean unloading a CoreML
    // chain and warming it again, which is seconds of silence for a slider the
    // user is still dragging.
    var speed: Double { get set }
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

    // 0…1 loudness of what is being said at this instant, 0 when silent. For
    // anything that has to *show* the voice rather than describe it.
    var currentLevel: Float { get }

    // Whether sound is actually coming out right now. `speak` covers synthesis
    // *and* playback, and on the enhanced voice the synthesis is the slow half —
    // so between the call and the first sample there are seconds in which
    // nothing is audible. A drawing of the voice made during that window is
    // showing speech that has not started: it reads as stuck, and then jumps
    // when the audio finally begins.
    var isPlaying: Bool { get }
}

extension Speaker {
    // Not every engine can answer this. The system voice speaks straight
    // through AVSpeechSynthesizer and never hands us the samples, so it has no
    // level to report — a drawing that needs one is expected to keep moving
    // without it, because "Aloud is talking" is the part that matters and
    // "how loud" is the part that is nice to have.
    var currentLevel: Float { 0 }

    // Engines that can't say are assumed to be playing the whole time `speak`
    // is in flight — the same forgiving default as the level above.
    var isPlaying: Bool { true }
}
