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
    // -warnings-as-errors.
    nonisolated(unsafe) private let synthesizer = AVSpeechSynthesizer()

    // Keyed by the utterance it belongs to, not a single slot.
    //
    // One slot was right while every consumer built its own speaker. SpeakerPool
    // now hands the *same* instance to the agent bridge and to the Settings
    // preview, so two `speak` calls can be in flight at once — and with one slot
    // the second overwrote the first's handler before the first's `didCancel`
    // landed. The cancel then resumed the *second* caller, and the first's
    // continuation was never resumed at all: `speak` never returned, so
    // `agentSpeaking` stayed true forever, and from there every later speak and
    // listen threw `.busy` and the user's own hotkey was refused. Dictation and
    // Agent Speak both dead until relaunch, from pressing preview at the wrong
    // moment.
    //
    // Removing-and-calling under the lock is what makes it safe: exactly one
    // caller can take a given handler, so a continuation is resumed once and
    // belongs to the utterance that actually ended.
    nonisolated(unsafe) private var finishHandlers: [ObjectIdentifier: () -> Void] = [:]
    // The utterance this speaker is currently meant to be saying, so a call
    // that was superseded can tell that it was.
    nonisolated(unsafe) private var currentUtterance: ObjectIdentifier?
    private let handlerLock = NSLock()
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
        // Built before the stop, so the utterance this call waits on is a
        // distinct object from any the stop is about to cancel.
        let mine = utterance(for: trimmed)
        stop()
        // Which utterance this instance is meant to be saying. The speakers are
        // pooled, so the Settings preview and an agent's question share one —
        // and a `didCancel` reads exactly like a `didFinish` from inside the
        // continuation. Without this, an agent whose question was cut off by
        // somebody pressing the preview button was told it had been spoken.
        setCurrent(mine)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            register({ continuation.resume() }, for: mine)
            synthesizer.speak(mine)
        }
        // Normally already taken by the callback that resumed us; this only
        // matters on a path where one never arrives, so a handler cannot
        // outlive the call that registered it.
        _ = takeHandler(for: mine)
        guard isCurrent(mine) else { throw SpeakerError.superseded }
    }

    private func setCurrent(_ utterance: AVSpeechUtterance) {
        handlerLock.lock(); defer { handlerLock.unlock() }
        currentUtterance = ObjectIdentifier(utterance)
    }

    private func isCurrent(_ utterance: AVSpeechUtterance) -> Bool {
        handlerLock.lock(); defer { handlerLock.unlock() }
        return currentUtterance == ObjectIdentifier(utterance)
    }

    private func register(_ handler: @escaping () -> Void, for utterance: AVSpeechUtterance) {
        handlerLock.lock(); defer { handlerLock.unlock() }
        finishHandlers[ObjectIdentifier(utterance)] = handler
    }

    private func takeHandler(for utterance: AVSpeechUtterance) -> (() -> Void)? {
        handlerLock.lock(); defer { handlerLock.unlock() }
        return finishHandlers.removeValue(forKey: ObjectIdentifier(utterance))
    }

    // Renders to buffers instead of the speakers, so synthesis is verifiable
    // headlessly and comparable against the enhanced voice on timing.
    func synthesize(_ text: String) async throws -> Speech {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpeakerError.emptyText }

        let started = Date()
        var samples: [Float] = []
        var rate = 0

        // The buffer callback outlives the call that started it: AVSpeechSynthesizer
        // keeps handing over buffers after the terminator, and it holds the closure
        // until it is done with the whole utterance. Two things follow.
        //
        // `self` is captured strongly so the synthesizer cannot be deallocated
        // while it still owns a callback into it — a speaker built for one
        // `synthesize` and released the moment it returned took the synthesizer
        // down with it mid-write.
        //
        // `done` closes the door behind the terminator, so a late buffer cannot
        // append to `samples` while the caller below is already reading it.
        let writeLock = NSLock()
        var done = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            synthesizer.write(utterance(for: trimmed)) { [self] buffer in
                _ = self
                writeLock.lock()
                guard !done else { writeLock.unlock(); return }
                // A zero-length buffer is the terminator, not audio.
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    done = true
                    writeLock.unlock()
                    continuation.resume()
                    return
                }
                rate = Int(pcm.format.sampleRate)
                samples.append(contentsOf: Self.mono(from: pcm))
                writeLock.unlock()
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
        // Unguarded on purpose. `isSpeaking` is false for the window between
        // handing an utterance over and the first sample leaving the speakers,
        // and a stop arriving in that window used to do nothing at all — so
        // ending a session while the question was still being queued let the
        // Mac read it out to a screen with no pill on it. The enhanced voice
        // has an explicit fix for the same race; the system voice is what every
        // user hears until the download lands, and what non-English users hear
        // permanently, so it needs one at least as much.
        //
        // `stopSpeaking(at:)` is safe on an idle synthesizer and also flushes
        // anything still queued behind the current utterance, which is exactly
        // what the guard was preventing.
        handlerLock.lock()
        currentUtterance = nil
        handlerLock.unlock()
        synthesizer.stopSpeaking(at: .immediate)
    }
}

extension SystemSpeaker: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        takeHandler(for: utterance)?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        takeHandler(for: utterance)?()
    }
}
