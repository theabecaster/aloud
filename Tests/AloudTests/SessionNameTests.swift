import XCTest
@testable import Aloud

// The name is what the user reads on the pill, hears in the spoken prompt, and
// picks from when more than one session wants the microphone. The harness id
// cannot do that job: two windows of the same tool are both "claude-code", and
// that is exactly the moment telling them apart matters.
final class SessionNameTests: XCTestCase {
    func testASessionMustSayWhatItIsDoing() {
        XCTAssertEqual(SessionName.validate(nil), .failure(.missing))
        XCTAssertEqual(SessionName.validate(""), .failure(.missing))
        XCTAssertEqual(SessionName.validate("   "), .failure(.missing))
    }

    func testTwoWordsIsTheBudget() {
        XCTAssertEqual(try? SessionName.validate("fixing tests").get(), "fixing tests")
        XCTAssertEqual(try? SessionName.validate("review").get(), "review")
        // This lands inside a spoken sentence and inside a button in a
        // 360-point menu, and a sentence survives neither.
        XCTAssertEqual(SessionName.validate("fixing the failing migration tests"),
                       .failure(.tooManyWords))
    }

    // Whitespace is collapsed before counting, so the rule cannot be dodged by
    // spacing and "fixing  tests" is the same name as "fixing tests".
    func testSpacingIsNormalizedBeforeItIsJudged() {
        XCTAssertEqual(try? SessionName.validate("  fixing   tests \n").get(), "fixing tests")
        XCTAssertEqual(SessionName.validate("a b c"), .failure(.tooManyWords))
    }

    func testAVeryLongTwoWordNameIsStillRefused() {
        let long = String(repeating: "x", count: SessionName.maxCharacters + 1)
        XCTAssertEqual(SessionName.validate(long), .failure(.tooLong))
    }

    // The refusals are read by an agent, not a person: each has to say what
    // would have worked, or the retry fails the same way.
    func testEveryRefusalTellsTheAgentWhatToSendInstead() {
        for invalid: SessionName.Invalid in [.missing, .tooManyWords, .tooLong] {
            XCTAssertTrue(invalid.message.contains("--name"), invalid.message)
        }
    }
}
