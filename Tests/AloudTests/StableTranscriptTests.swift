import XCTest
@testable import Aloud

final class StableTranscriptTests: XCTestCase {
    // A word appears only once a second decode has agreed on it.
    func testReleasesOnSecondAgreement() {
        var s = StableTranscript()
        XCTAssertNil(s.accept("hello"))                  // first sighting, hold it
        XCTAssertEqual(s.accept("hello there"), "hello") // agreed → released
        XCTAssertEqual(s.accept("hello there world"), "hello there")
    }

    // The leading edge churns every pass; none of that reaches the screen.
    func testUnstableTailNeverTyped() {
        var s = StableTranscript()
        XCTAssertNil(s.accept("the qui"))            // nothing agreed yet
        XCTAssertEqual(s.accept("the quick"), "the") // only "the"; the half-word waits
        XCTAssertEqual(s.accept("the quick bro"), "the quick")
        XCTAssertNil(s.accept("the quick brown"))    // "bro" was never typed, "brown" isn't agreed
        XCTAssertEqual(s.text, "the quick")
    }

    // A shorter hypothesis that still matches the screen confirms nothing new
    // and must never delete text the user is reading.
    func testNeverShrinksOnWeakerHypothesis() {
        var s = StableTranscript()
        _ = s.accept("one two three")
        XCTAssertEqual(s.accept("one two three"), "one two three")
        XCTAssertNil(s.accept("one two"))
        XCTAssertNil(s.accept("one"))
        XCTAssertEqual(s.text, "one two three")
    }

    // A real correction — two decodes in a row disagreeing with the screen —
    // does go through.
    func testRevisesOnSustainedDisagreement() {
        var s = StableTranscript()
        _ = s.accept("i scream cones")
        XCTAssertEqual(s.accept("i scream cones"), "i scream cones")
        XCTAssertNil(s.accept("ice cream cones"))                    // first disagreement
        XCTAssertEqual(s.accept("ice cream cones today"), "ice cream cones")
    }

    // The decoder re-punctuates the whole utterance as it hears more. A
    // one-off flip is not new information and must not retype anything; a
    // rendering two consecutive decodes agree on is the decoder's settled
    // opinion and does update the screen.
    func testPunctuationFlapIsNotAChange() {
        var s = StableTranscript()
        _ = s.accept("three main topics first the")
        XCTAssertEqual(s.accept("three main topics first the"), "three main topics first the")
        XCTAssertNil(s.accept("three main topics. First the"))  // one-off flip: ignored
        XCTAssertNil(s.accept("three main topics first the"))   // …and it flapped back
        XCTAssertEqual(s.text, "three main topics first the")
        // Two decodes in a row rendering "topics." adopt it; "First," vs
        // "First" is still dithering, so that word keeps waiting.
        XCTAssertNil(s.accept("three main topics. First, the quarterly"))
        XCTAssertEqual(s.accept("three main topics. First the quarterly budget"),
                       "three main topics. first the quarterly")
    }

    // The observed pain: a spurious period released mid-sentence used to sit
    // there, visibly wrong, until commit. Once the decoder firmly drops it —
    // two consecutive decodes without it — the screen heals.
    func testStrayPunctuationHeals() {
        var s = StableTranscript()
        _ = s.accept("we cover topics. First")
        XCTAssertEqual(s.accept("we cover topics. First"), "we cover topics. First")
        XCTAssertNil(s.accept("we cover topics first thing"))
        XCTAssertEqual(s.accept("we cover topics first thing today"),
                       "we cover topics first thing")
    }

    // Silence decodes to nothing; that is not a signal to erase.
    func testEmptyDecodeKeepsText() {
        var s = StableTranscript()
        _ = s.accept("keep this")
        XCTAssertEqual(s.accept("keep this"), "keep this")
        XCTAssertNil(s.accept(""))
        XCTAssertEqual(s.text, "keep this")
    }

    // Whitespace shape is normalized, so re-spacing alone never retypes.
    func testWhitespaceNormalized() {
        var s = StableTranscript()
        _ = s.accept("hello   world")
        XCTAssertEqual(s.accept(" hello world "), "hello world")
        XCTAssertNil(s.accept("hello  world"))
    }

    // Steady speech keeps flowing: every decode releases the previous one's tail.
    func testGrowsMonotonically() {
        var s = StableTranscript()
        var typed: [String] = []
        for hypothesis in ["a", "a b", "a b c", "a b c d"] {
            if let text = s.accept(hypothesis) { typed.append(text) }
        }
        XCTAssertEqual(typed, ["a", "a b", "a b c"])
        // Each update is a pure extension of the last — no backspacing.
        for (previous, next) in zip(typed, typed.dropFirst()) {
            XCTAssertTrue(next.hasPrefix(previous))
        }
    }
}
