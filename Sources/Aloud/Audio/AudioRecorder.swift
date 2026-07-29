import AVFoundation
import CoreAudio

// Microphone capture: AVAudioEngine input tap, converted live to 16 kHz mono
// Float32 (what the transcription engine expects). Start on hotkey-down, stop
// on release; `stop()` returns the accumulated samples.
final class AudioRecorder {
    static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    // Every touch of `engine` (start, stop, a mid-session rebuild, a device
    // configuration change) runs serialized through here. A noise-reduction
    // toggle's rebuild is the one caller that dispatches to it asynchronously
    // — reconfiguring the engine can take the better part of a second, and it
    // has no reason to hold the main thread hostage while it does. Everyone
    // else still calls in with `sync`, so from their side nothing changed.
    private let engineQueue = DispatchQueue(label: "com.abrahamgonzalez.aloud.audiorecorder.engine")
    private(set) var isRecording = false
    // Remembered for the mid-session rebuild below, which starts a fresh
    // engine and has to re-apply the same processing.
    private var noiseReduction = false

    // Live input level (0…1) for the recording indicator, updated on the tap queue.
    private(set) var currentLevel: Float = 0

    // Live per-frequency-band levels (0…1 each) for the indicator's spectrum.
    // The analyser is fed on the tap thread, reset from the main one when a
    // session starts or ends, and its result read from the main one every
    // frame — so everything about it, analyser included, goes through this
    // lock. A tap callback can still be in flight when stop() runs, and the
    // analyser carries mutable buffers across calls.
    private let analyzer = SpectrumAnalyzer()
    private let bandsLock = NSLock()
    private var bands: [Float] = SpectrumAnalyzer.silent
    var currentBands: [Float] {
        bandsLock.lock(); defer { bandsLock.unlock() }
        return bands
    }

    // Optional live consumer of converted 16 kHz chunks, invoked on the tap
    // thread as audio arrives (live typing feeds its streaming session here).
    // Samples still accumulate for `stop()` regardless. Cleared on stop.
    var onChunk: (([Float]) -> Void)?

    // Second, independent chunk consumer for passive listeners (speech
    // detection) that must keep running whether or not live typing owns
    // `onChunk`. Same thread, same cleared-on-stop contract.
    var onMonitorChunk: (([Float]) -> Void)?

    // Whether macOS voice processing was actually engaged for this session —
    // some interfaces (aggregate devices, a few USB mics) refuse it, and we
    // record raw rather than fail the dictation. Written on engineQueue
    // (applyVoiceProcessing runs there), read from main; goes through `lock`
    // like every other cross-thread field here.
    private var _voiceProcessingActive = false
    var voiceProcessingActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return _voiceProcessingActive
    }
    private func noteVoiceProcessingActive(_ active: Bool) {
        lock.lock(); defer { lock.unlock() }
        _voiceProcessingActive = active
    }
    // Set when voice processing was engaged, produced nothing but digital
    // silence, and capture was rebuilt without it. Reported by --mic-check.
    private(set) var voiceProcessingFellBack = false

    // "Has this session heard anything at all yet" — any sample that isn't
    // exactly zero. A real microphone in a silent room still has a noise
    // floor, so all-zeros means the capture path is dead, not that the room
    // is quiet. Guarded by `lock`, written on the tap thread.
    private var sawSignal = false
    // Uptime of the first sample that wasn't digital silence, and of the
    // moment capture started — how long the input took to actually deliver
    // anything. Diagnostic only.
    private var firstSignalUptime: TimeInterval?
    private var captureStartUptime: TimeInterval = 0
    private var silenceWatchdog: DispatchWorkItem?
    // Why the engine last refused to start. Kept for diagnostics (--mic-check)
    // — "couldn't start" on its own tells nobody anything.
    private(set) var lastStartError: Error?

    // Fires (on the main queue) after the input device disappeared mid-session
    // and capture was rebuilt on the current default input.
    var onDeviceChange: (() -> Void)?

    // Which microphones are known to go silent under voice processing, and a
    // way to report a newly discovered one. Injected rather than read from
    // settings so capture stays testable and knows nothing about preferences.
    var isDeviceDeafUnderVoiceProcessing: ((String) -> Bool)?
    var onVoiceProcessingWentDeaf: ((String) -> Void)?
    private var sessionDeviceUID: String?
    private var configObserver: NSObjectProtocol?
    // Which device this session actually started on. macOS posts a
    // configuration change for things that are not device changes at all —
    // voice processing settling right after the engine starts is the common
    // one — and telling the user their microphone changed every time they
    // began dictating was both wrong and, since the note takes the pill's
    // meter slot, in the way.
    private var sessionDeviceID: AudioDeviceID = 0
    // Set for the span of a noise-reduction-triggered rebuild, main-thread
    // only (set and cleared from setNoiseReduction's main-queue callers).
    // Reconfiguring voice processing posts the same configuration-change
    // notification a real device swap does; without this, that self-fired
    // echo would try to rebuild again on an engineQueue still busy with the
    // rebuild that caused it, and block main waiting its turn.
    private var isRebuildingForNoiseReduction = false
    // A configuration change arrived while that flag was up. Almost always
    // the echo — but a microphone really unplugged in that sub-second window
    // posts the identical notification, and dropping *that* would leave a
    // dead tap. Once the rebuild settles, this remembers there is something
    // to double-check; the device ID says whether it was real.
    private var sawConfigChangeDuringRebuild = false

    // Which device the engine's input unit is pointed at right now.
    private func currentInputDeviceID() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard let au = engine.inputNode.audioUnit else { return 0 }
        AudioUnitGetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &id, &size)
        return id
    }

    // Select a specific input device by pointing the engine's input AU at it.
    // No-op (default device) when uid is nil or stale.
    private func applyInputDevice(uid: String?) {
        guard let uid, let deviceID = AudioDevices.deviceID(forUID: uid) else { return }
        var id = deviceID
        let au = engine.inputNode.audioUnit
        if let au {
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &id,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
    }

    // macOS voice processing (the same path FaceTime and Dictation use):
    // echo cancellation against whatever the Mac is playing, plus background
    // noise suppression. Must be toggled while the engine is stopped — it
    // swaps the input audio unit underneath us, which also invalidates any
    // device selection and the node's format, so this runs first.
    //
    // AGC is deliberately left off. It rides the gain up through the pauses
    // between phrases, which in a noisy room means amplifying exactly the
    // chatter we're trying to suppress; the model handles quiet speech better
    // than it handles pumped-up room tone.
    private func applyVoiceProcessing(_ enabled: Bool) {
        let input = engine.inputNode
        guard input.isVoiceProcessingEnabled != enabled else {
            noteVoiceProcessingActive(enabled)
            return
        }
        do {
            try input.setVoiceProcessingEnabled(enabled)
            if enabled { input.isVoiceProcessingAGCEnabled = false }
            noteVoiceProcessingActive(enabled)
        } catch {
            // Not every input device supports it. Recording raw is a worse
            // experience than recording processed, but a far better one than
            // not recording at all.
            noteVoiceProcessingActive(false)
        }
    }

    // Last line of defence for the above. If voice processing is engaged and
    // the first moment of the session is *exactly* zero on every sample, the
    // capture path is dead — rebuild it without voice processing rather than
    // let the user talk into a microphone that isn't listening. Runs at most
    // once per session, and only costs the fraction of a second of silence it
    // just proved was worthless.
    // Deliberately generous. Inputs can take the better part of a second to
    // deliver their first real sample — a raw built-in microphone measured
    // 0.67 s here — so a tight deadline would switch voice processing off on
    // hardware that was merely slow to wake.
    private static let silenceGrace: TimeInterval = 1.5

    private func startSilenceWatchdog() {
        silenceWatchdog?.cancel()
        guard voiceProcessingActive else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording,
                  VoiceProcessingGuard.shouldFallBack(
                    voiceProcessingActive: self.voiceProcessingActive,
                    heardAnything: self.heardAnything,
                    alreadyFellBack: self.voiceProcessingFellBack)
            else { return }
            self.voiceProcessingFellBack = true
            self.noiseReduction = false
            // No notice: the microphone did not change and nothing the user
            // did caused this. It recovers inside a second, and the only
            // honest thing to say about it is nothing.
            // Same shape as the toggle's rebuild: off main (so nothing on
            // screen freezes while the engine restarts), with the flag up so
            // the reconfiguration's own configuration-change echo doesn't
            // trigger a second rebuild on its heels.
            self.isRebuildingForNoiseReduction = true
            self.engineQueue.async { [weak self] in
                guard let self else { return }
                _ = self.rebuildCapture()
                DispatchQueue.main.async { self.settleRebuildEcho() }
            }
        }
        silenceWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.silenceGrace, execute: work)
    }

    // Remember this microphone as one that hears nothing under voice
    // processing, so the next session skips it rather than rediscovering the
    // same silence.
    private func reportDeafDevice() {
        guard let uid = sessionDeviceUID else { return }
        onVoiceProcessingWentDeaf?(uid)
    }

    // Whether this session has heard anything but digital silence. Exposed so
    // --mic-check can tell "the room is quiet" from "the capture path is dead",
    // which an RMS reading alone cannot.
    var heardAnything: Bool {
        lock.lock(); defer { lock.unlock() }
        return sawSignal
    }

    // Seconds between capture starting and the first sample that wasn't
    // digital silence. nil when nothing has been heard at all.
    var secondsToFirstSignal: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard let firstSignalUptime else { return nil }
        return firstSignalUptime - captureStartUptime
    }

    // Turn background-noise filtering on or off in the middle of a session —
    // the badge on the recording pill. Rebuilding capture costs a fraction of
    // a second of audio, which is the honest price of the switch doing what it
    // says the moment it is pressed rather than at some later dictation. Runs
    // off the main thread so whatever animated the badge to its optimistic
    // state keeps rendering while the engine catches up, instead of freezing
    // mid-animation; `completion` reports what actually happened, on the main
    // queue, once it has.
    // Ignored when the microphone has already proved it goes deaf under it.
    func setNoiseReduction(_ enabled: Bool, completion: ((Bool) -> Void)? = nil) {
        let allowed = enabled && !(sessionDeviceUID.map { isDeviceDeafUnderVoiceProcessing?($0) ?? false } ?? false)
        guard isRecording, allowed != voiceProcessingActive else {
            noiseReduction = allowed
            completion?(voiceProcessingActive)
            return
        }
        noiseReduction = allowed
        // Reconfiguring voice processing fires the same
        // AVAudioEngineConfigurationChange notification a real device change
        // does. With the rebuild off the main thread, that echo now arrives
        // while this one is still running and its handler would block main
        // waiting its turn on engineQueue — the stutter this flag prevents.
        isRebuildingForNoiseReduction = true
        engineQueue.async { [weak self] in
            guard let self else { return }
            _ = self.rebuildCapture()
            let active = self.voiceProcessingActive
            DispatchQueue.main.async {
                self.startSilenceWatchdog()
                completion?(active)
                self.settleRebuildEcho()
            }
        }
    }

    // A noise-reduction rebuild just finished (main thread). Drop the guard,
    // and decide whether the configuration change it swallowed was real: the
    // device ID answers cheaply — the rebuild's own echo leaves it alone, a
    // microphone unplugged inside that window does not. Only a genuine swap
    // re-enters recovery.
    private func settleRebuildEcho() {
        isRebuildingForNoiseReduction = false
        guard sawConfigChangeDuringRebuild else { return }
        sawConfigChangeDuringRebuild = false
        if isRecording,
           engineQueue.sync(execute: { self.currentInputDeviceID() }) != sessionDeviceID {
            recoverFromConfigurationChange()
        }
    }

    // nil leaves the converter's own mapping alone, which is right for the
    // ordinary mono microphone. See the call site for what this prevents.
    static func channelMap(forInputChannels channels: AVAudioChannelCount) -> [NSNumber]? {
        channels > 1 ? [0] : nil
    }

    func start(deviceUID: String?, noiseReduction: Bool) throws {
        guard !isRecording else { return }
        // Under the lock: the previous session's tap can still deliver a
        // last buffer or two until its queued teardown runs, and these are
        // the fields it touches.
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        sawSignal = false
        firstSignalUptime = nil
        lock.unlock()
        currentLevel = 0
        resetSpectrum()
        voiceProcessingFellBack = false
        // Which microphone this will actually be — "system default" is a
        // moving target, and the answer decides whether voice processing is
        // safe to use here at all.
        sessionDeviceUID = deviceUID ?? AudioDevices.uid(forDeviceID: currentInputDeviceID())
        let deviceIsDeaf = sessionDeviceUID.map { isDeviceDeafUnderVoiceProcessing?($0) ?? false } ?? false
        self.noiseReduction = noiseReduction && !deviceIsDeaf

        try engineQueue.sync {
            applyVoiceProcessing(self.noiseReduction)
            applyInputDevice(uid: deviceUID)

            guard engine.inputNode.outputFormat(forBus: 0).sampleRate > 0 else {
                throw NSError(domain: "Aloud", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "No audio input available"])
            }
            guard installCapture() else {
                throw NSError(domain: "Aloud", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Couldn’t start listening"])
            }
        }
        isRecording = true
        captureStartUptime = ProcessInfo.processInfo.systemUptime
        sessionDeviceID = currentInputDeviceID()
        startSilenceWatchdog()

        // Unplugging the active mic (or an AirPods hand-off) fires a config
        // change and silences the tap. Rebuild capture on whatever input the
        // system now considers default; samples already recorded are kept.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.recoverFromConfigurationChange()
        }
    }

    private func recoverFromConfigurationChange() {
        guard isRecording else { return }
        // A rebuild already in flight for noise reduction will leave capture
        // in the right state on its own; this notification is almost surely
        // its own reconfiguration echoing back. Remember it rather than act:
        // the rebuild's completion re-checks the device in case a microphone
        // really did vanish inside that window.
        if isRebuildingForNoiseReduction {
            sawConfigChangeDuringRebuild = true
            return
        }
        // The rebuild happens on the engine's own queue, never inline: this
        // handler runs on main, and CoreAudio is free to post the
        // notification whenever it likes — including a beat after a
        // noise-reduction rebuild has already finished and dropped its
        // guard (enabling voice processing settles late). Blocking main here
        // was the stutter that froze the badge animation halfway.
        engineQueue.async { [weak self] in
            guard let self, self.isRecording, self.rebuildCapture() else { return }
            // Only a real change of device is worth telling the user about;
            // the rebuild above happens either way, because the tap is dead
            // either way.
            let now = self.currentInputDeviceID()
            DispatchQueue.main.async {
                guard self.isRecording, now != self.sessionDeviceID else { return }
                self.sessionDeviceID = now
                self.onDeviceChange?()
            }
        }
    }

    // Tear the running capture down and stand it back up on whatever the
    // engine's input is now, with whatever processing this session is
    // currently entitled to. Shared by the two things that invalidate a live
    // tap: the device changing underneath us, and voice processing turning out
    // to produce nothing. Samples already recorded are kept.
    @discardableResult
    private func rebuildCapture() -> Bool {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        applyVoiceProcessing(noiseReduction)
        return installCapture()
    }

    // Point the engine at the input, wire the graph for the processing in use,
    // and start it. Returns false when there is no usable input — the caller
    // decides whether that is fatal; a live session keeps whatever it already
    // recorded.
    private func installCapture() -> Bool {
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0,
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: Self.targetSampleRate,
                                               channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: hwFormat, to: targetFormat)
        else { return false }
        // Multi-channel inputs need to be told which channel to take. The
        // MacBook Pro's own microphone presents *three* channels (it's a
        // beam-forming array), and asking AVAudioConverter to fold that down
        // to mono without a channel map returns digital silence — every
        // sample exactly zero, no error, no warning. The pill sits there with
        // a dead meter and the dictation comes back empty, which is precisely
        // what "Aloud stopped hearing me" looks like. Measured on this Mac:
        // 0 of 30,197 samples non-zero without the map, 29,759 of 31,813 with
        // it. Channel 0 is the primary capture channel.
        //
        // Whether a session hits this depends on the format the input hands
        // over, and voice processing changes that format — which is how a
        // setting that has nothing to do with channel counts came to look
        // like the culprit.
        if let map = Self.channelMap(forInputChannels: hwFormat.channelCount) {
            converter.channelMap = map
        }
        self.converter = converter
        // AVAudioEngine raises (and so aborts the app) if a tap is already on
        // the bus. A previous start that got as far as the tap and then failed
        // to start the engine — another app holding the input, a device
        // disappearing mid-launch — leaves exactly that behind, so the next
        // hotkey press would crash rather than fail. Removing a tap that isn't
        // there is free.
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.consume(buffer: buffer, converter: converter, targetFormat: targetFormat)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            lastStartError = error
            input.removeTap(onBus: 0)   // never leave one behind for the next start
            return false
        }
        return true
    }

    // Stop and return 16 kHz mono samples.
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        silenceWatchdog?.cancel()
        silenceWatchdog = nil
        // The verdict on voice processing is only earned by comparison. The
        // watchdog switched it off mid-session because nothing had been heard;
        // if raw capture then heard something, voice processing was the reason
        // and this microphone should never use it again. If raw heard nothing
        // either, the room was simply quiet and voice processing is off the
        // hook — blaming it there would disable the feature on a good device
        // for the sin of being started in a silent moment.
        if VoiceProcessingGuard.shouldDistrustDevice(fellBack: voiceProcessingFellBack,
                                                     heardAfterFallback: heardAnything) {
            reportDeafDevice()
        }
        // Teardown queues behind any in-flight noise-reduction rebuild and
        // runs without this thread waiting on it — a release that lands right
        // after a toggle would otherwise stall main for the rest of that
        // rebuild. Nothing below needs the engine actually stopped: the
        // samples are snapshotted here, the few milliseconds the tap may
        // still deliver land in the old array, and the next start() clears it
        // after its own engineQueue turn — which FIFO puts after this one.
        engineQueue.async { [engine] in
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            // Leave the graph as raw capture found it, so a session that never
            // wanted voice processing never opens an output device.
            engine.disconnectNodeOutput(engine.inputNode)
        }
        isRecording = false
        converter = nil
        onChunk = nil
        onMonitorChunk = nil
        resetSpectrum()
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }

    func cancel() {
        _ = stop()
    }

    private func resetSpectrum() {
        bandsLock.lock()
        analyzer.reset()
        bands = SpectrumAnalyzer.silent
        bandsLock.unlock()
    }

    private func consume(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData else { return }
        let chunk = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        // RMS level for the indicator (cheap, on the tap thread).
        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = (sum / Float(max(chunk.count, 1))).squareRoot()
        currentLevel = min(1, rms * 12)
        // Frequency bands for the indicator, from the same converted chunk.
        bandsLock.lock()
        if let bands = analyzer.append(chunk) { self.bands = bands }
        bandsLock.unlock()
        lock.lock()
        if !sawSignal, chunk.contains(where: { $0 != 0 }) {
            sawSignal = true
            firstSignalUptime = ProcessInfo.processInfo.systemUptime
        }
        samples.append(contentsOf: chunk)
        lock.unlock()
        onChunk?(chunk)
        onMonitorChunk?(chunk)
    }
}
