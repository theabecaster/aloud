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
    private(set) var isRecording = false

    // Live input level (0…1) for the recording indicator, updated on the tap queue.
    private(set) var currentLevel: Float = 0

    // Optional live consumer of converted 16 kHz chunks, invoked on the tap
    // thread as audio arrives (live typing feeds its streaming session here).
    // Samples still accumulate for `stop()` regardless. Cleared on stop.
    var onChunk: (([Float]) -> Void)?

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

    func start(deviceUID: String?) throws {
        guard !isRecording else { return }
        samples.removeAll(keepingCapacity: true)
        currentLevel = 0
        applyInputDevice(uid: deviceUID)

        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw NSError(domain: "Aloud", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio input available"])
        }
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: Self.targetSampleRate,
                                               channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw NSError(domain: "Aloud", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Audio format conversion unavailable"])
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.consume(buffer: buffer, converter: converter, targetFormat: targetFormat)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    // Stop and return 16 kHz mono samples.
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil
        onChunk = nil
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }

    func cancel() {
        _ = stop()
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
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
        onChunk?(chunk)
    }

    var recordedDuration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / Self.targetSampleRate
    }
}
