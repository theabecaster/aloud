import XCTest
@testable import Aloud

final class ChunkedLivePreviewTests: XCTestCase {
    private let target = ChunkedLivePreview.rollTargetSamples
    private let cap = ChunkedLivePreview.hardCapSamples

    // Inside one window it behaves exactly like the old whole-buffer preview:
    // StableTranscript's two-decode agreement, nothing else.
    func testSingleWindowMatchesStableTranscript() {
        var p = ChunkedLivePreview()
        XCTAssertNil(p.accept("hello", decodedEnd: 16_000, tailQuiet: false))
        XCTAssertEqual(p.accept("hello there", decodedEnd: 32_000, tailQuiet: false), "hello")
        XCTAssertEqual(p.windowStart, 0)
    }

    // A quiet trailing edge before the roll target must not end the chunk.
    func testNoRollBeforeTarget() {
        var p = ChunkedLivePreview()
        _ = p.accept("one two", decodedEnd: target - 1, tailQuiet: true)
        XCTAssertEqual(p.windowStart, 0)
    }

    // Past the target, a pause ends the chunk: the whole hypothesis — even the
    // words agreement was still holding back — freezes and shows at once.
    func testQuietTailRollsAndPromotesHypothesis() {
        var p = ChunkedLivePreview()
        _ = p.accept("one two three", decodedEnd: target - 10_000, tailQuiet: false)
        let display = p.accept("one two three four", decodedEnd: target, tailQuiet: true)
        XCTAssertEqual(display, "one two three four")
        XCTAssertEqual(p.windowStart, target)
    }

    // Continuous speech keeps the window open past the target…
    func testLoudTailDefersRoll() {
        var p = ChunkedLivePreview()
        _ = p.accept("one two three", decodedEnd: target + 20_000, tailQuiet: false)
        XCTAssertEqual(p.windowStart, 0)
    }

    // …until the hard cap, which rolls no matter what.
    func testHardCapForcesRoll() {
        var p = ChunkedLivePreview()
        let display = p.accept("one two three", decodedEnd: cap, tailQuiet: false)
        XCTAssertEqual(display, "one two three")
        XCTAssertEqual(p.windowStart, cap)
    }

    // Text keeps accumulating across a roll: the new window's confirmed words
    // append after the frozen chunk, nothing duplicated, nothing lost.
    func testTextAccumulatesAcrossRoll() {
        var p = ChunkedLivePreview()
        _ = p.accept("first chunk", decodedEnd: target, tailQuiet: true)     // roll
        XCTAssertNil(p.accept("second", decodedEnd: target + 16_000, tailQuiet: false))
        XCTAssertEqual(p.accept("second chunk", decodedEnd: target + 32_000, tailQuiet: false),
                       "first chunk second")
        XCTAssertEqual(p.accept("second chunk done", decodedEnd: target + 48_000, tailQuiet: false),
                       "first chunk second chunk")
    }

    // A window that is nothing but a filler — the decoder hallucinating from
    // the room tone of a pause — never shows and never freezes.
    func testFillerOnlyWindowWithheld() {
        var p = ChunkedLivePreview()
        _ = p.accept("real words here", decodedEnd: target, tailQuiet: true)  // roll
        XCTAssertNil(p.accept("Yeah.", decodedEnd: target + 16_000, tailQuiet: false))
        XCTAssertNil(p.accept("Yeah.", decodedEnd: target + 32_000, tailQuiet: false))
        // Even a roll during the hallucination freezes nothing.
        XCTAssertNil(p.accept("Yeah.", decodedEnd: 2 * target + 32_000, tailQuiet: true))
        XCTAssertEqual(p.windowStart, 2 * target + 32_000)
        // Real speech in the next window continues after the first chunk only.
        _ = p.accept("more speech", decodedEnd: 2 * target + 48_000, tailQuiet: false)
        XCTAssertEqual(p.accept("more speech", decodedEnd: 2 * target + 64_000, tailQuiet: false),
                       "real words here more speech")
    }

    // An all-silence window (empty hypothesis) rolls quietly without smearing
    // empty strings into the frozen text.
    func testEmptyHypothesisRollsClean() {
        var p = ChunkedLivePreview()
        _ = p.accept("spoken part", decodedEnd: target, tailQuiet: true)      // roll
        XCTAssertNil(p.accept("", decodedEnd: 2 * target, tailQuiet: true))   // silent roll
        XCTAssertEqual(p.windowStart, 2 * target)
        _ = p.accept("tail", decodedEnd: 2 * target + 16_000, tailQuiet: false)
        XCTAssertEqual(p.accept("tail words", decodedEnd: 2 * target + 32_000, tailQuiet: false),
                       "spoken part tail")
    }

    // Nothing spoken yet: no display, ever, even across rolls.
    func testSilenceOnlySessionShowsNothing() {
        var p = ChunkedLivePreview()
        XCTAssertNil(p.accept("", decodedEnd: target, tailQuiet: true))
        XCTAssertNil(p.accept("", decodedEnd: 2 * target, tailQuiet: true))
    }

    // MARK: tailIsQuiet

    private func samples(_ spans: [(seconds: Double, amplitude: Float)]) -> [Float] {
        spans.flatMap { [Float](repeating: $0.amplitude, count: Int($0.seconds * 16_000)) }
    }

    func testTailQuietDetectsPauseAfterSpeech() {
        let window = samples([(11.0, 0.05), (0.5, 0.0005)])
        XCTAssertTrue(ChunkedLivePreview.tailIsQuiet(window))
    }

    func testTailNotQuietMidSpeech() {
        let window = samples([(11.5, 0.05)])
        XCTAssertFalse(ChunkedLivePreview.tailIsQuiet(window))
    }

    func testAllSilentWindowCountsAsQuiet() {
        let window = samples([(11.5, 0.0)])
        XCTAssertTrue(ChunkedLivePreview.tailIsQuiet(window))
    }

    func testTooShortWindowNeverQuiet() {
        XCTAssertFalse(ChunkedLivePreview.tailIsQuiet(samples([(0.1, 0.0)])))
    }
}
