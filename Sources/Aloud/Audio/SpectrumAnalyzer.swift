import Accelerate
import Foundation

// Turns the live 16 kHz capture stream into a handful of frequency-band levels
// for the recording indicator: a real short-time spectrum, not a single volume
// number smeared across a row of bars.
//
// Why bands and not RMS: one level says "something is loud", which a slammed
// door satisfies as well as a sentence. A spectrum shows the shape of what the
// mic hears, so a person watching the pill can tell their voice is landing —
// vowels light the low bands, consonants flick the high ones.
//
// Deliberately honest rather than lively. Each bar reports how far its band
// rises above the room's own noise in that band, so a fan, a café or a laptop
// under load leaves the meter alone and a voice fills it. Nothing here invents
// motion: with no one talking, the bars sit down.
final class SpectrumAnalyzer {
    static let bandCount = 14

    // 512 samples at 16 kHz = 32 ms, 31.25 Hz per bin: enough resolution to
    // separate the low bands, short enough that the meter tracks syllables.
    private static let fftSize = 512
    private static let hop = 256
    private static let log2n = vDSP_Length(9)   // log2(512)

    // Band edges span the range that carries speech at this sample rate
    // (Nyquist is 8 kHz), spaced logarithmically so the bars divide what the
    // ear divides rather than what the FFT does.
    private static let lowestHz: Float = 80
    private static let highestHz: Float = 6_500

    // Each bar measures how far its band rises above the room, not how loud it
    // is in absolute terms. A fixed threshold can't do this job: hiss from a
    // fan sits above any floor low enough to catch the quiet top end of a
    // voice, so a fixed meter either ignores consonants or lights up in an
    // empty room. Tracking the floor per band means the bars answer the
    // question the user is actually asking — "is it hearing *me*?"
    //
    // Full height is this far above the tracked floor.
    private static let spanDB: Float = 52
    // A band has to clear its floor by this much before it reads as anything,
    // which keeps the noise itself from wobbling the bars.
    private static let marginDB: Float = 5

    // The floor drops toward a quieter frame at this rate (fast: the gaps
    // between syllables re-anchor it within a few frames) and creeps up at a
    // fixed crawl, so continuous speech can't drag it along behind itself.
    private static let floorFallCoefficient: Float = 0.4
    private static let floorRiseDBPerFrame: Float = 0.05
    // Bounds: below the first the room is effectively silent, above the second
    // a loud room would start hiding a loud voice.
    private static let floorMinDB: Float = -95
    private static let floorMaxDB: Float = -32
    // Starts pessimistic so the first frames of a session can't flash noise
    // before the tracker has settled.
    private static let floorStartDB: Float = -45

    // Speech energy falls with frequency and so, less steeply, does the noise
    // it sits in. This stretches the upper bands' headroom a little so
    // consonants register as more than a twitch.
    private static let topBandGain: Float = 1.35

    // Frames quieter than this are reported as pure silence — digital silence
    // and a muted input have nothing to show above any floor.
    private static let gateRMS: Float = 0.0008

    private let setup: FFTSetup
    private let window: [Float]
    private let bandRanges: [(lower: Int, upper: Int)]
    private let bandGain: [Float]
    private var noiseFloorDB = [Float](repeating: floorStartDB, count: bandCount)

    // Samples waiting for a full frame. Kept small: never more than one frame.
    private var pending: [Float] = []

    private var real = [Float](repeating: 0, count: fftSize / 2)
    private var imag = [Float](repeating: 0, count: fftSize / 2)
    private var magnitudes = [Float](repeating: 0, count: fftSize / 2)

    init(sampleRate: Float = Float(AudioRecorder.targetSampleRate)) {
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&w, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        window = w

        let binHz = sampleRate / Float(Self.fftSize)
        let ratio = Self.highestHz / Self.lowestHz
        var ranges: [(Int, Int)] = []
        var gains: [Float] = []
        for i in 0..<Self.bandCount {
            let lowHz = Self.lowestHz * pow(ratio, Float(i) / Float(Self.bandCount))
            let highHz = Self.lowestHz * pow(ratio, Float(i + 1) / Float(Self.bandCount))
            // Bin 0 is DC (and, in a packed real FFT, Nyquist) — never a band.
            let lower = max(1, Int((lowHz / binHz).rounded(.down)))
            let upper = min(Self.fftSize / 2 - 1, max(lower, Int((highHz / binHz).rounded(.up)) - 1))
            ranges.append((lower, upper))
            let position = Float(i) / Float(Self.bandCount - 1)
            gains.append(1 + (Self.topBandGain - 1) * position)
        }
        bandRanges = ranges
        bandGain = gains
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    static var silent: [Float] { [Float](repeating: 0, count: bandCount) }

    func reset() {
        pending.removeAll(keepingCapacity: true)
        for i in noiseFloorDB.indices { noiseFloorDB[i] = Self.floorStartDB }
    }

    // Feed captured samples; returns the newest band levels (0…1) once enough
    // audio has arrived, or nil while a frame is still filling. Safe to call
    // from the audio tap thread — this object is owned by one thread at a time.
    @discardableResult
    func append(_ samples: [Float]) -> [Float]? {
        pending.append(contentsOf: samples)
        guard pending.count >= Self.fftSize else { return nil }
        var latest: [Float]?
        // A capture buffer usually holds several frames. Every frame is
        // analysed and the last one wins: the meter shows the present, and
        // hopping keeps it from skipping over a short syllable entirely.
        while pending.count >= Self.fftSize {
            latest = bands(frame: Array(pending[0..<Self.fftSize]))
            pending.removeFirst(Self.hop)
        }
        // Keep at most a frame's worth of tail so a long stall can't grow this.
        if pending.count > Self.fftSize { pending.removeFirst(pending.count - Self.fftSize) }
        return latest
    }

    // One 512-sample frame → band levels. Stateful by design: each call also
    // updates this band's idea of what the room sounds like, which is what the
    // levels are measured against.
    func bands(frame: [Float]) -> [Float] {
        guard frame.count == Self.fftSize else { return Self.silent }

        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(Self.fftSize))
        guard rms >= Self.gateRMS else { return Self.silent }

        var windowed = [Float](repeating: 0, count: Self.fftSize)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(Self.fftSize))

        let half = Self.fftSize / 2
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }
        // vDSP's packed real FFT returns twice the textbook magnitude, and the
        // Hann window halves it again; this puts a full-scale tone back at 1.0.
        var scale = 2 / Float(Self.fftSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(half))

        return (0..<Self.bandCount).map { i in
            let range = bandRanges[i]
            var peak: Float = 0
            vDSP_maxv(Array(magnitudes[range.lower...range.upper]), 1, &peak,
                      vDSP_Length(range.upper - range.lower + 1))
            // A band is as loud as its loudest bin, not its average: voices are
            // harmonics with gaps between them, and averaging across the wide
            // upper bands flattens exactly the detail worth showing.
            let db = 20 * log10(max(peak, 1e-9))
            let floor = trackFloor(band: i, db: db)
            let above = (db - floor - Self.marginDB) * bandGain[i]
            return min(max(above / Self.spanDB, 0), 1)
        }
    }

    // Rolling estimate of what this band looks like when nobody is talking.
    private func trackFloor(band i: Int, db: Float) -> Float {
        var floor = noiseFloorDB[i]
        floor += db < floor
            ? (db - floor) * Self.floorFallCoefficient
            : Self.floorRiseDBPerFrame
        floor = min(max(floor, Self.floorMinDB), Self.floorMaxDB)
        noiseFloorDB[i] = floor
        return floor
    }
}
