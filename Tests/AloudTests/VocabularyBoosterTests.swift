import XCTest
@testable import Aloud

final class VocabularyBoosterGateTests: XCTestCase {

    private let terms = [
        Replacement(pattern: "Dente Eye", replacement: "DentAI"),
        Replacement(pattern: "Stewie", replacement: "Stuey"),
    ]

    func testGenuineConfusionPasses() {
        // The model wrote the known misspelling; the rescorer swapped in the
        // term. Textually adjacent to the alias — believable.
        XCTAssertTrue(VocabularyBooster.plausibleRescore(
            original: "working on dente eye today",
            rescored: "working on DentAI today",
            terms: terms))
    }

    func testNearMissOfTheAliasPasses() {
        XCTAssertTrue(VocabularyBooster.plausibleRescore(
            original: "ask Stevie about it",
            rescored: "ask Stuey about it",
            terms: terms))
    }

    func testAcousticMisfireOntoAnUnrelatedWordIsRejected() {
        // The regression that shipped this gate: a name that sounds nothing
        // like any term still won on acoustic score alone.
        XCTAssertFalse(VocabularyBooster.plausibleRescore(
            original: "say hi to John Smyth",
            rescored: "say hi to John DentAI",
            terms: terms))
    }

    func testSwapNoTermAccountsForIsRejected() {
        XCTAssertFalse(VocabularyBooster.plausibleRescore(
            original: "meet me at noon",
            rescored: "meet me at midnight",
            terms: terms))
    }

    func testOneBadSwapRejectsTheWholeRescore() {
        XCTAssertFalse(VocabularyBooster.plausibleRescore(
            original: "dente eye and John Smyth",
            rescored: "DentAI and John DentAI",
            terms: terms))
    }

    func testUntouchedTranscriptPasses() {
        XCTAssertTrue(VocabularyBooster.plausibleRescore(
            original: "nothing changed here",
            rescored: "nothing changed here",
            terms: terms))
    }
}
