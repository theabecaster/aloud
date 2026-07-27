import XCTest
@testable import Aloud

final class SpectrumAnalyzerTests: XCTestCase {
    private let sampleRate: Float = 16_000
    private let frameSize = 512

    private func tone(_ hz: Float, amplitude: Float = 0.2) -> [Float] {
        (0..<frameSize).map { amplitude * sin(2 * .pi * hz * Float($0) / sampleRate) }
    }

    private func hiss(rms: Float, seed: UInt64 = 7) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        _ = seed
        return (0..<frameSize).map { _ in Float.random(in: -1...1, using: &rng) * rms * 1.7 }
    }

    // Feed the same frame repeatedly: the noise-floor tracker needs a moment to
    // settle before any reading means anything, exactly as in a live session.
    private func settled(_ analyzer: SpectrumAnalyzer, on frame: [Float], frames: Int = 40) -> [Float] {
        var last = SpectrumAnalyzer.silent
        for _ in 0..<frames { last = analyzer.bands(frame: frame) }
        return last
    }

    func testShapeAndRange() {
        let analyzer = SpectrumAnalyzer()
        let bands = analyzer.bands(frame: tone(500))
        XCTAssertEqual(bands.count, SpectrumAnalyzer.bandCount)
        XCTAssertEqual(SpectrumAnalyzer.silent.count, SpectrumAnalyzer.bandCount)
        for value in bands { XCTAssertTrue(value >= 0 && value <= 1, "band out of range: \(value)") }
    }

    // The whole point of the meter: what lights up tells you *where* in the
    // spectrum the mic is hearing something, not merely that it is.
    func testTonesLightTheirOwnBand() {
        let low = SpectrumAnalyzer().bands(frame: tone(300))
        let high = SpectrumAnalyzer().bands(frame: tone(3_000))
        guard let lowPeak = low.firstIndex(of: low.max() ?? 0),
              let highPeak = high.firstIndex(of: high.max() ?? 0) else {
            return XCTFail("no band responded to a pure tone")
        }
        XCTAssertLessThan(lowPeak, SpectrumAnalyzer.bandCount / 2, "300 Hz should sit in the low half")
        XCTAssertGreaterThan(highPeak, SpectrumAnalyzer.bandCount * 2 / 3, "3 kHz should sit in the high bands")
        XCTAssertGreaterThan(highPeak, lowPeak + 4, "the two tones should be bands apart")
        // And a tone lights its own neighbourhood only.
        XCTAssertLessThan(low.suffix(4).max() ?? 1, 0.05)
        XCTAssertLessThan(high.prefix(4).max() ?? 1, 0.05)
    }

    func testSilenceReadsAsSilence() {
        let analyzer = SpectrumAnalyzer()
        let bands = settled(analyzer, on: [Float](repeating: 0, count: frameSize))
        XCTAssertEqual(bands, SpectrumAnalyzer.silent)
    }

    // A fan, a laptop, a café: steady room noise has to settle out, or the
    // meter says "I hear you" to an empty room and the feedback is worthless.
    func testSteadyRoomNoiseSettlesOut() {
        let analyzer = SpectrumAnalyzer()
        let room = hiss(rms: 0.003)   // ≈ −50 dBFS, an audibly quiet room
        let bands = settled(analyzer, on: room, frames: 80)
        XCTAssertLessThan(bands.max() ?? 1, 0.25, "room noise should not read as a voice")
    }

    // …and a voice-like tone on top of that same room still reads loud and
    // clear. Rejecting the noise is only useful if the signal survives.
    func testVoiceRisesOutOfRoomNoise() {
        let analyzer = SpectrumAnalyzer()
        let room = hiss(rms: 0.003)
        _ = settled(analyzer, on: room, frames: 80)
        let voiced = zip(room, tone(600, amplitude: 0.08)).map(+)
        let bands = analyzer.bands(frame: voiced)
        XCTAssertGreaterThan(bands.max() ?? 0, 0.5, "speech-level energy should fill the meter")
    }

    // The capture path hands over chunks of whatever size CoreAudio chose;
    // the analyser buffers them into frames on its own.
    func testBuffersPartialChunks() {
        let analyzer = SpectrumAnalyzer()
        XCTAssertNil(analyzer.append(Array(tone(400)[0..<200])))
        XCTAssertNil(analyzer.append(Array(tone(400)[200..<400])))
        let bands = analyzer.append(Array(tone(400)[0..<200]))
        XCTAssertEqual(bands?.count, SpectrumAnalyzer.bandCount)
    }

    // A new session starts from a clean room, not the last one's.
    func testResetClearsTheFloor() {
        let analyzer = SpectrumAnalyzer()
        _ = settled(analyzer, on: hiss(rms: 0.02), frames: 60)
        analyzer.reset()
        XCTAssertNil(analyzer.append([Float](repeating: 0, count: 100)))
        XCTAssertEqual(analyzer.bands(frame: [Float](repeating: 0, count: frameSize)),
                       SpectrumAnalyzer.silent)
    }
}
