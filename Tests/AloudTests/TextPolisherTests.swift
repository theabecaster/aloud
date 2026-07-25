import XCTest
@testable import Aloud

final class TextPolisherTests: XCTestCase {
    private func polish(_ s: String, level: PolishLevel = .standard,
                        replacements: [Replacement] = []) -> String {
        TextPolisher(level: level, replacements: replacements).polish(s)
    }

    // MARK: off

    func testOffIsUntouched() {
        XCTAssertEqual(polish("um, so like  this .", level: .off), "um, so like  this .")
    }

    // MARK: spoken numbers

    func testNumbersAreWrittenOutFromLightUp() {
        XCTAssertEqual(polish("can we get the report at three p.m.", level: .light),
                       "Can we get the report at 3 PM")
        XCTAssertEqual(polish("it went up twenty percent"), "It went up 20%")
    }

    func testOffKeepsSpokenNumbers() {
        XCTAssertEqual(polish("at three p.m.", level: .off), "at three p.m.")
    }

    func testNumbersFollowTheDeclaredLanguage() {
        var polisher = TextPolisher(level: .standard, replacements: [])
        polisher.languages = ["es"]
        XCTAssertEqual(polisher.polish("cuarenta y dos euros"), "42 euros")
        // A language without a number table is left exactly as dictated.
        polisher.languages = ["nl"]
        XCTAssertEqual(polisher.polish("veertig euro"), "Veertig euro")
    }

    func testPreviewHoldsTheTrailingNumber() {
        var polisher = TextPolisher(level: .standard, replacements: [])
        polisher.capitalizeNames = false
        polisher.finalPass = false
        XCTAssertEqual(polisher.polish("meet me at three"), "Meet me at three")
    }

    // MARK: fillers

    func testFillerRemoval() {
        XCTAssertEqual(polish("Um, I think, uh, we should go."), "I think, we should go.")
        XCTAssertEqual(polish("So, um, yes."), "So, yes.")
        XCTAssertEqual(polish("Hmm. That works."), "That works.")
    }

    func testFillerInsideWordsUntouched() {
        XCTAssertEqual(polish("The umbrella and the summit."), "The umbrella and the summit.")
        // "like"/"you know" carry meaning — never removed.
        XCTAssertEqual(polish("I like this, you know it."), "I like this, you know it.")
    }

    // MARK: self-corrections

    func testScratchThat() {
        XCTAssertEqual(polish("Send it Tuesday, scratch that, send it Friday."),
                       "Send it Friday.")
        XCTAssertEqual(polish("We met at noon. Order pizza, no wait, order sushi."),
                       "We met at noon. Order sushi.")
    }

    func testScratchThatOnlyInStandard() {
        XCTAssertEqual(polish("A, scratch that, B.", level: .light), "A, scratch that, B.")
    }

    // MARK: replacements

    func testReplacements() {
        let reps = [Replacement(pattern: "sequel", replacement: "SQL")]
        XCTAssertEqual(polish("I wrote some sequel today.", replacements: reps),
                       "I wrote some SQL today.")
        // whole-word only
        XCTAssertEqual(polish("Sequels are fun.", replacements: reps), "Sequels are fun.")
    }

    // MARK: proper nouns

    func testNamesCapitalized() {
        XCTAssertEqual(polish("tell john the meeting moved to london"),
                       "Tell John the meeting moved to London")
        XCTAssertEqual(polish("we visited tokyo and kyoto", level: .light),
                       "We visited Tokyo and Kyoto")
        XCTAssertEqual(polish("send the report to maria gonzalez at microsoft"),
                       "Send the report to Maria Gonzalez at Microsoft")
    }

    func testCommonWordsNeverCapitalized() {
        // "invoice"/"acme" read as organization names to the tagger, but both
        // are lexicon words — the conservative filter must hold them back.
        XCTAssertEqual(polish("the invoice from acme corporation is overdue"),
                       "The invoice from acme corporation is overdue")
        XCTAssertEqual(polish("the quick brown fox jumps over the lazy dog"),
                       "The quick brown fox jumps over the lazy dog")
    }

    func testNamePassOnlyWithPolishOn() {
        XCTAssertEqual(polish("say hi to maria gonzalez", level: .off),
                       "say hi to maria gonzalez")
    }

    func testReplacementProductsUntouchedByNamePass() {
        // The user asked for lowercase "chellie" — exactly what they typed wins.
        let reps = [Replacement(pattern: "shelly", replacement: "chellie")]
        XCTAssertEqual(polish("Ask shelly to review it.", replacements: reps),
                       "Ask chellie to review it.")
    }

    // MARK: tidy

    func testTidySpacingAndCapitalization() {
        XCTAssertEqual(polish("hello  world . next one"), "Hello world. Next one")
        XCTAssertEqual(polish(", leading comma gone"), "Leading comma gone")
    }

    func testDecimalNumbersNotCapitalized() {
        XCTAssertEqual(polish("it costs $427.62 total"), "It costs $427.62 total")
    }

    func testEmptyAndWhitespace() {
        XCTAssertEqual(polish(""), "")
        XCTAssertEqual(polish("   "), "")
        // A transcript that is nothing but fillers collapses to empty (nothing injected).
        XCTAssertEqual(polish("um, uh."), "")
    }
}
