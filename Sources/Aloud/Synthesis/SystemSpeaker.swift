import AVFoundation

// The zero-download voice: AVSpeechSynthesizer, always present, no assets to
// fetch and nothing to warm. It is the reason `speak` never has a broken
// state — only a less good one — which is what lets the enhanced voice be
// fetched quietly in the background instead of blocking first run.
//
// It is also the only voice that covers every language Aloud ships, so the
// consent prompt ("… wants to listen") goes through here for non-English
// users regardless of what the enhanced voice can do.
final class SystemSpeaker: NSObject, Speaker {
    // AVSpeechSynthesizerDelegate is Sendable-refined, so conforming makes this
    // class Sendable and its non-Sendable stored properties an error under
    // -warnings-as-errors. Both are only ever touched from the one `speak` /
    // `synthesize` call in flight (each awaits its own completion before
    // returning) and from the delegate callbacks that call answers, so the
    // access is already serialized — there is no second writer to race.
    nonisolated(unsafe) private let synthesizer = AVSpeechSynthesizer()
    nonisolated(unsafe) private var finishHandler: (() -> Void)?
    // The voice the user picked, if they picked one of this engine's. nil means
    // "whatever this Mac says best", which is also what a picked voice degrades
    // to once it stops being installed.
    private let voiceIdentifier: String?
    nonisolated(unsafe) var speed: Double = VoiceSpeed.normal

    var state: SpeakerState { .ready }
    var modelIsDownloaded: Bool { true }

    func prepare() async throws {}

    init(voiceIdentifier: String? = nil) {
        self.voiceIdentifier = voiceIdentifier
        super.init()
        synthesizer.delegate = self
    }

    // The picked voice, or the best one for the user's language. macOS ships a
    // compact voice for every locale and downloads better ones on demand
    // (System Settings → Accessibility → Spoken Content), so the fallback
    // prefers the highest quality present rather than naming a voice we can't
    // guarantee exists — and a picked voice that has since been deleted falls
    // back to it rather than going silent.
    private func voice() -> AVSpeechSynthesisVoice? {
        if let voiceIdentifier, let picked = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            return picked
        }
        let language = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == language || $0.language.hasPrefix(String(language.prefix(2)))
        }
        let ranked = candidates.max { a, b in rank(a.quality) < rank(b.quality) }
        return ranked ?? AVSpeechSynthesisVoice(language: language)
    }

    private func rank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 3
        case .enhanced: return 2
        case .default: return 1
        @unknown default: return 0
        }
    }

    private func utterance(for text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice()
        utterance.rate = Self.rate(for: speed)
        return utterance
    }

    // AVSpeechUtterance's rate is not a multiplier — it is a 0…1 dial whose
    // midpoint (`AVSpeechUtteranceDefaultSpeechRate`, 0.5) is the voice's
    // natural pace. Scaling that midpoint keeps our own 1× meaning the same
    // thing here as it does on the enhanced voice, and the clamp keeps a
    // slider that runs past either end from producing a voice nobody can
    // follow.
    private static func rate(for speed: Double) -> Float {
        let scaled = AVSpeechUtteranceDefaultSpeechRate * Float(VoiceSpeed.clamped(speed))
        return min(max(scaled, AVSpeechUtteranceMinimumSpeechRate),
                   AVSpeechUtteranceMaximumSpeechRate)
    }

    func speak(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpeakerError.emptyText }
        stop()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            finishHandler = {
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            synthesizer.speak(utterance(for: trimmed))
        }
        finishHandler = nil
    }

    // Renders to buffers instead of the speakers, so synthesis is verifiable
    // headlessly and comparable against the enhanced voice on timing.
    func synthesize(_ text: String) async throws -> Speech {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpeakerError.emptyText }

        let started = Date()
        var samples: [Float] = []
        var rate = 0

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            let finish = {
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            synthesizer.write(utterance(for: trimmed)) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { finish(); return }
                // A zero-length buffer is the terminator, not audio.
                guard pcm.frameLength > 0 else { finish(); return }
                rate = Int(pcm.format.sampleRate)
                samples.append(contentsOf: Self.mono(from: pcm))
            }
        }

        guard !samples.isEmpty else {
            throw SpeakerError.synthesisFailed("the system voice produced no audio")
        }
        return Speech(samples: samples, sampleRate: rate,
                      synthesisTime: Date().timeIntervalSince(started))
    }

    // AVSpeechSynthesizer hands back Int16 on most voices and Float32 on some;
    // normalize to Float32 so one player serves both engines.
    private static func mono(from buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength)
        if let float = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: float[0], count: count))
        }
        if let int16 = buffer.int16ChannelData {
            return UnsafeBufferPointer(start: int16[0], count: count)
                .map { Float($0) / Float(Int16.max) }
        }
        return []
    }

    // The system voice starts speaking as soon as it is asked, so this is
    // simply whether it is mid-utterance.
    var isPlaying: Bool { synthesizer.isSpeaking }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}

extension SystemSpeaker: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        finishHandler?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        finishHandler?()
    }
}
