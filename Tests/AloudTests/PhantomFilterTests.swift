import XCTest
@testable import Aloud

// Confidence values below are measured, not invented — see PhantomFilter for
// where the two populations sit.
final class PhantomFilterTests: XCTestCase {
    func testFillerOnlyRecognisesBareNoiseWords() {
        XCTAssertTrue(PhantomFilter.isFillerOnly("Yeah."))
        XCTAssertTrue(PhantomFilter.isFillerOnly("yeah"))
        XCTAssertTrue(PhantomFilter.isFillerOnly("Mm-hmm."))
        XCTAssertTrue(PhantomFilter.isFillerOnly("  Um,  "))
    }

    func testFillerOnlyLeavesRealSentencesAlone() {
        XCTAssertFalse(PhantomFilter.isFillerOnly("Yeah, let's ship it."))
        XCTAssertFalse(PhantomFilter.isFillerOnly("um so the build is broken"))
        XCTAssertFalse(PhantomFilter.isFillerOnly(""))
    }

    // Words someone might genuinely dictate on their own are not in the list at
    // any confidence — whispered, they score inside the phantom band.
    func testStandaloneRealWordsAreNeverFillers() {
        for word in ["Okay.", "Sure.", "Thank you.", "Thanks.", "No.", "Bye."] {
            XCTAssertFalse(PhantomFilter.isFillerOnly(word), word)
            XCTAssertFalse(PhantomFilter.isPhantom(text: word, confidence: 0.73), word)
        }
    }

    // The bug: a short burst of room tone decoding as "Yeah." with no one
    // having said anything. Observed range across 17 reproductions.
    func testPhantomFromSilenceIsDiscarded() {
        for confidence in [Float(0.56), 0.62, 0.65, 0.80] {
            XCTAssertTrue(PhantomFilter.isPhantom(text: "Yeah.", confidence: confidence))
        }
        XCTAssertTrue(PhantomFilter.isPhantom(text: "Mm-hmm.", confidence: 0.80))
    }

    // A filler the decoder is sure of was really said — that one ships.
    func testConfidentFillerSurvives() {
        XCTAssertFalse(PhantomFilter.isPhantom(text: "Yeah.", confidence: 0.90))
    }

    // The point of using confidence rather than loudness: a whisper scores like
    // speech because it is speech, so quiet dictation is untouched.
    func testWhisperedSpeechIsUntouched() {
        XCTAssertFalse(PhantomFilter.isPhantom(
            text: "Hey, can you send me the report when you get a chance?", confidence: 0.95))
        // A whispered "yeah" still reads as spoken — measured 0.90+ even when
        // scaled down to the noise floor.
        XCTAssertFalse(PhantomFilter.isPhantom(text: "Yeah.", confidence: 0.91))
    }

    // Real words are never dropped, however unsure the decoder is of them.
    func testRealWordsSurviveLowConfidence() {
        XCTAssertFalse(PhantomFilter.isPhantom(text: "Push the launch back a week.",
                                               confidence: 0.20))
    }

    // Engines with no real confidence signal report 1 and opt out entirely.
    func testEnginesWithoutConfidenceAreNotSecondGuessed() {
        XCTAssertFalse(PhantomFilter.isPhantom(text: "Yeah.", confidence: 1))
    }
}
