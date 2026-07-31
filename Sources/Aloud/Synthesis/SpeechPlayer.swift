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

    // 0…1, and 0 whenever nothing is playing.
    var currentLevel: Float {
        levelLock.lock(); defer { levelLock.unlock() }
        guard let startedAt else { return 0 }
        return envelope.level(at: ProcessInfo.processInfo.systemUptime - startedAt)
    }

    private func beginLevels(_ speech: Speech) {
        let built = SpeechEnvelope(samples: speech.samples, sampleRate: speech.sampleRate)
        levelLock.lock(); defer { levelLock.unlock() }
        envelope = built
        startedAt = ProcessInfo.processInfo.systemUptime
    }

    private func endLevels() {
        levelLock.lock(); defer { levelLock.unlock() }
        startedAt = nil
    }

    // Resolves when playback finishes, or immediately if it was interrupted by
    // a newer utterance or by stop().
    func play(_ speech: Speech) async throws {
        guard !speech.samples.isEmpty else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(speech.sampleRate),
                                         channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(speech.samples.count)),
              let channel = buffer.floatChannelData
        else { throw SpeakerError.playbackFailed("couldn't build an output buffer") }

        buffer.frameLength = AVAudioFrameCount(speech.samples.count)
        speech.samples.withUnsafeBufferPointer { src in
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
        var scheduleFailure: String?
        // Started here rather than at the top: everything above can still
        // throw, and a level clock running for audio that never played would
        // draw a voice nobody heard.
        beginLevels(speech)
        defer { endLevels() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // AVFAudio still raises from here on format edge cases we haven't
            // hit; a failed utterance must degrade, never abort the process.
            if let raised = AloudCatchException({
                node.scheduleBuffer(buffer, at: nil, options: .interrupts,
                                    completionCallbackType: .dataPlayedBack) { _ in
                    continuation.resume()
                }
                node.play()
            }) {
                scheduleFailure = raised.reason ?? raised.name.rawValue
                continuation.resume()
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
