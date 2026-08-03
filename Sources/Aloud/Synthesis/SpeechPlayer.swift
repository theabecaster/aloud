import AloudObjC
import AVFoundation

// Plays synthesized PCM through the default output device.
//
// One utterance at a time on purpose: a second `play` interrupts the first,
// because two voices talking over each other is never what was wanted. The
// half-duplex gate that keeps the microphone from hearing our own speech is
// built on `play` not returning until the audio has actually finished.
final class SpeechPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var wired = false
    private var currentFormat: AVAudioFormat?

    // What is being said right now, for anything drawing the voice. Written
    // here on the playback path and read from the main thread at display rate,
    // so it carries its own lock rather than trusting the two to agree.
    private let levelLock = NSLock()
    private var envelope = SpeechEnvelope(frames: [])
    private var startedAt: TimeInterval?
    // Which utterance the clock above belongs to. `play` is built for a second
    // call to interrupt the first, and the first then resumes and runs its
    // `defer` — so without a token it clears the clock of the utterance that is
    // currently audible, and the pill stops drawing a voice mid-sentence.
    private var levelRun = 0
    private var idleWork: DispatchWorkItem?

    // Whether samples are going out of the speakers at this instant.
    var isPlaying: Bool {
        levelLock.lock(); defer { levelLock.unlock() }
        return startedAt != nil
    }

    // 0…1, and 0 whenever nothing is playing.
    var currentLevel: Float {
        levelLock.lock(); defer { levelLock.unlock() }
        guard let startedAt else { return 0 }
        return envelope.level(at: ProcessInfo.processInfo.systemUptime - startedAt)
    }

    private func beginLevels(_ speech: Speech) -> Int {
        let built = SpeechEnvelope(samples: speech.samples, sampleRate: speech.sampleRate)
        levelLock.lock(); defer { levelLock.unlock() }
        idleWork?.cancel()
        idleWork = nil
        envelope = built
        startedAt = ProcessInfo.processInfo.systemUptime
        levelRun += 1
        return levelRun
    }

    // Only the utterance that owns the clock may stop it.
    private func endLevels(_ run: Int) {
        levelLock.lock(); defer { levelLock.unlock() }
        guard run == levelRun else { return }
        startedAt = nil
    }

    // Let the output device go once nothing has been said for a while.
    //
    // The engine is started on the first utterance and, before this, was never
    // stopped: `shutdown()` had no callers at all. In a menu-bar app that runs
    // for weeks that means one agent question — or one press of the preview
    // button — pins the default output open for the rest of the session, which
    // on Bluetooth can hold the headset in call mode.
    //
    // Deferred rather than immediate because a conversation is several
    // utterances with pauses between them, and tearing the engine down between
    // two sentences would put the cold lead-in back in front of each of them.
    private static let idleShutdown: TimeInterval = 20

    private func scheduleIdleShutdown(after run: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            levelLock.lock()
            let stillIdle = startedAt == nil && run == levelRun
            levelLock.unlock()
            guard stillIdle else { return }
            shutdown()
        }
        levelLock.lock()
        // A newer utterance started while this one was finishing: it owns the
        // engine now, and its own completion will arm the next timer.
        guard run == levelRun else { levelLock.unlock(); return }
        idleWork?.cancel()
        idleWork = work
        levelLock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleShutdown, execute: work)
    }

    // Resolves when playback finishes, or immediately if it was interrupted by
    // a newer utterance or by stop().
    // Silence scheduled ahead of the speech, so the output device has something
    // to swallow while it wakes up. `engine.start()` returns before the hardware
    // is actually rendering — on a cold engine, and worse on Bluetooth — and
    // whatever is at the front of the buffer during that gap is simply never
    // heard. It cost the first few words of an agent's question: the user saw
    // the pill talking and heard nothing until halfway through the sentence.
    //
    // A running engine is already warm, so it only needs enough to cover the
    // node starting.
    private static let coldLeadIn: TimeInterval = 0.45
    private static let warmLeadIn: TimeInterval = 0.1

    // MARK: the silence on the end
    //
    // Synthesizers pad their output. Measured on this Mac for one sentence:
    // kokoro 0.43s of trailing silence, supertonic 0.36s, pocket 0.12s, the
    // system voice 0.04s.
    //
    // Playback completes on `.dataPlayedBack`, which means the whole buffer —
    // so for the best part of half a second after the voice has audibly
    // stopped, `isPlaying` is still true, `play` has not returned, and every
    // caller downstream is still waiting. The pill goes on drawing the talking
    // animation at somebody who can hear that nothing is being said, and the
    // microphone opens later than it needed to. Reported as "the agent
    // animation hung again for a while after the agent stopped talking".
    //
    // Trimming it is better than shortening the *timer*, because it is not a
    // timing problem: the silence is real audio being dutifully played, and
    // once it is gone every consumer of "is it still speaking" becomes correct
    // at once.
    private static let silenceFloor: Float = 0.01   // of peak; below this is inaudible
    // Kept so a final consonant or a natural decay is not clipped. Generous
    // next to what is being removed, and cheap to be wrong about in this
    // direction — a clipped word is a defect, a little extra silence is not.
    private static let keptTail: TimeInterval = 0.06

    static func trimmingTrailingSilence(_ speech: Speech) -> Speech {
        guard !speech.samples.isEmpty else { return speech }
        var peak: Float = 0
        for sample in speech.samples { peak = max(peak, abs(sample)) }
        // Digital silence throughout: nothing to trim, and nothing to play
        // either. Leave it exactly as it came.
        guard peak > 0 else { return speech }
        let floor = peak * silenceFloor
        guard let lastAudible = speech.samples.lastIndex(where: { abs($0) > floor })
        else { return speech }
        let end = min(speech.samples.count - 1,
                      lastAudible + Int(keptTail * Double(speech.sampleRate)))
        guard end < speech.samples.count - 1 else { return speech }
        return Speech(samples: Array(speech.samples[...end]),
                      sampleRate: speech.sampleRate,
                      synthesisTime: speech.synthesisTime)
    }

    func play(_ unpadded: Speech) async throws {
        let speech = Self.trimmingTrailingSilence(unpadded)
        guard !speech.samples.isEmpty else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(speech.sampleRate),
                                         channels: 1)
        else { throw SpeakerError.playbackFailed("couldn't build an output buffer") }

        // The pad goes into the envelope as well as the buffer, so the drawing
        // of the voice stays in step with it: silence reads as silence, and the
        // wave swells when the speech actually arrives rather than at the
        // moment we asked for it.
        let leadIn = engine.isRunning ? Self.warmLeadIn : Self.coldLeadIn
        let padded = Speech(samples: [Float](repeating: 0,
                                             count: Int(leadIn * Double(speech.sampleRate)))
                                + speech.samples,
                            sampleRate: speech.sampleRate,
                            synthesisTime: speech.synthesisTime)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(padded.samples.count)),
              let channel = buffer.floatChannelData
        else { throw SpeakerError.playbackFailed("couldn't build an output buffer") }

        buffer.frameLength = AVAudioFrameCount(padded.samples.count)
        padded.samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            channel[0].update(from: base, count: src.count)
        }

        // Connect with the *buffer's* format, not nil. A nil format makes the
        // node adopt the mixer's rate, and scheduling a 24 kHz mono buffer onto
        // a node connected at the output device's rate raises an NSException
        // from scheduleBuffer — an uncatchable SIGABRT in Swift. The mixer
        // resamples for us as long as the connection describes what we feed it.
        // Engines differ (22.05 kHz system voice, 24 kHz enhanced), so rewire
        // whenever the rate changes.
        if !wired || currentFormat?.sampleRate != format.sampleRate {
            if wired { engine.disconnectNodeOutput(node) } else { engine.attach(node) }
            engine.connect(node, to: engine.mainMixerNode, format: format)
            currentFormat = format
            wired = true
        }
        if !engine.isRunning {
            do { try engine.start() }
            catch { throw SpeakerError.playbackFailed(error.localizedDescription) }
        }

        // .dataPlayedBack, not the default .dataConsumed: the latter fires as
        // soon as the buffer has been handed to the render thread, which is
        // well before the user has heard it.
        // `.interrupts` only when there is something to interrupt. Scheduling
        // it onto a node that was just stopped races that stop: the buffer
        // goes into the queue and the stop still unwinding behind it flushes
        // part of what was queued, so the utterance comes out cut short — a
        // sample that says half its sentence and stops. Nothing to interrupt
        // means nothing to flush.
        let options: AVAudioPlayerNodeBufferOptions = node.isPlaying ? .interrupts : []

        var scheduleFailure: String?
        // Started here rather than at the top: everything above can still
        // throw, and a level clock running for audio that never played would
        // draw a voice nobody heard.
        let run = beginLevels(padded)
        defer {
            endLevels(run)
            scheduleIdleShutdown(after: run)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Two things can resume this: the completion callback, and the
            // failure path below. Once the buffer is scheduled the node owns a
            // callback we cannot take back, so whether that callback fires
            // before or after a raise out of `play()` is not ours to decide —
            // and resuming a CheckedContinuation twice traps the process.
            // Whoever gets here first wins; the other is a no-op.
            let resumeLock = NSLock()
            var resumed = false
            let resumeOnce = {
                resumeLock.lock()
                let first = !resumed
                resumed = true
                resumeLock.unlock()
                if first { continuation.resume() }
            }
            // AVFAudio still raises from here on format edge cases we haven't
            // hit; a failed utterance must degrade, never abort the process.
            if let raised = AloudCatchException({
                node.scheduleBuffer(buffer, at: nil, options: options,
                                    completionCallbackType: .dataPlayedBack) { _ in
                    resumeOnce()
                }
                node.play()
            }) {
                scheduleFailure = raised.reason ?? raised.name.rawValue
                resumeOnce()
            }
        }
        if let scheduleFailure { throw SpeakerError.playbackFailed(scheduleFailure) }
    }

    // Stopping the node fires the pending completion callback, so an awaiting
    // play() returns rather than hanging.
    func stop() {
        guard wired else { return }
        node.stop()
    }

    // Release the output device. Holding an idle engine keeps the hardware
    // awake, and on Bluetooth it can pin the headset into call mode.
    func shutdown() {
        stop()
        if engine.isRunning { engine.stop() }
    }
}
