import AVFoundation
import Foundation

// Safety net for failed dictations: when transcription errors out, the
// session's audio is kept as a WAV in the state dir so the user can retry —
// including after a relaunch. Cleared the moment any dictation succeeds;
// nothing is ever kept for sessions that worked.
enum AudioBackup {
    static var fileURL: URL { AppPaths.stateDir.appendingPathComponent("last-failed.wav") }

    static var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    static func save(samples: [Float], to url: URL? = nil) {
        let fileURL = url ?? fileURL
        if url == nil { AppPaths.ensureStateDir() }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: AudioRecorder.targetSampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try? FileManager.default.removeItem(at: fileURL)
        guard let file = try? AVAudioFile(forWriting: fileURL, settings: format.settings,
                                          commonFormat: .pcmFormatFloat32, interleaved: false)
        else { return }
        try? file.write(from: buffer)
    }

    static func load(from url: URL? = nil) -> [Float]? {
        let fileURL = url ?? fileURL
        guard let file = try? AVAudioFile(forReading: fileURL, commonFormat: .pcmFormatFloat32,
                                          interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        guard (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData
        else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
