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

    func testBadlyMangledNamesStillPass() {
        // The case boosting exists for: the model has never seen the name and
        // writes something only vaguely like it. A gate tight enough to reject
        // this would only ever let through what the plain text pass already
        // catches.
        let siobhan = [Replacement(pattern: "shivon", replacement: "Siobhan")]
        XCTAssertTrue(VocabularyBooster.plausibleRescore(
            original: "ask chevaun about it",
            rescored: "ask Siobhan about it",
            terms: siobhan))

        let k8s = [Replacement(pattern: "kubernets", replacement: "Kubernetes")]
        XCTAssertTrue(VocabularyBooster.plausibleRescore(
            original: "deploy it on coobernetties",
            rescored: "deploy it on Kubernetes",
            terms: k8s))
    }

    func testAnUncheckableChangeIsRejected() {
        // A rewritten run too long to read as vocabulary yields no candidate
        // pairs at all. Not being able to check is not the same as passing.
        XCTAssertFalse(VocabularyBooster.plausibleRescore(
            original: "the quick brown fox jumped over it",
            rescored: "a totally different sentence entirely now",
            terms: terms))
    }

    func testSwapJudgedAgainstEveryTermItCouldBelongTo() {
        // Two terms share a word; the swap must be judged against the one that
        // actually explains it, not whichever happens to be listed first.
        let both = [
            Replacement(pattern: "acme corp", replacement: "ACME Corporation"),
            Replacement(pattern: "widgets", replacement: "Corporation Widgets"),
        ]
        XCTAssertTrue(VocabularyBooster.plausibleRescore(
            original: "call acme corp today",
            rescored: "call ACME Corporation today",
            terms: both))
    }
}
