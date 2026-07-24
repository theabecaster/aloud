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
