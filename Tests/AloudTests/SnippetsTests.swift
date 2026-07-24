import XCTest
@testable import Aloud

final class SnippetMatcherTests: XCTestCase {
    private let snippets = [
        Snippet(trigger: "my email", expansion: "abe@example.com"),
        Snippet(trigger: "sig", expansion: "Best,\nAbe"),
    ]

    func testExactMatch() {
        XCTAssertEqual(SnippetMatcher.expansion(for: "my email", snippets: snippets),
                       "abe@example.com")
    }

    // The matcher sees polished text, which capitalizes and can add a period.
    func testForgivesCaseWhitespaceAndTrailingPunctuation() {
        XCTAssertEqual(SnippetMatcher.expansion(for: "My email.", snippets: snippets),
                       "abe@example.com")
        XCTAssertEqual(SnippetMatcher.expansion(for: "  MY EMAIL!  ", snippets: snippets),
                       "abe@example.com")
        XCTAssertEqual(SnippetMatcher.expansion(for: "Sig,", snippets: snippets), "Best,\nAbe")
    }

    func testInsertForms() {
        XCTAssertEqual(SnippetMatcher.expansion(for: "Insert sig", snippets: snippets),
                       "Best,\nAbe")
        XCTAssertEqual(SnippetMatcher.expansion(for: "Insert my email.", snippets: snippets),
                       "abe@example.com")
        // "insert my <trigger>" for triggers that don't start with "my".
        XCTAssertEqual(SnippetMatcher.expansion(for: "Insert my sig", snippets: snippets),
                       "Best,\nAbe")
    }

    // A trigger inside a longer sentence is just words — expanding it would
    // corrupt ordinary dictation.
    func testMidSentenceNeverMatches() {
        XCTAssertNil(SnippetMatcher.expansion(for: "Send it to my email please", snippets: snippets))
        XCTAssertNil(SnippetMatcher.expansion(for: "my email address", snippets: snippets))
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(SnippetMatcher.expansion(for: "hello there", snippets: snippets))
        XCTAssertNil(SnippetMatcher.expansion(for: "", snippets: snippets))
        XCTAssertNil(SnippetMatcher.expansion(for: "my email", snippets: []))
    }

    // Punctuation-only utterances must not match an (invalid) empty trigger.
    func testEmptyTriggerIgnored() {
        let bad = [Snippet(trigger: "  ", expansion: "boom")]
        XCTAssertNil(SnippetMatcher.expansion(for: "...", snippets: bad))
    }

    func testTriggerWithTrailingPunctuationInSettings() {
        let s = [Snippet(trigger: "brb.", expansion: "be right back")]
        XCTAssertEqual(SnippetMatcher.expansion(for: "Brb", snippets: s), "be right back")
    }

    func testFirstMatchWins() {
        let dupes = [Snippet(trigger: "x", expansion: "first"),
                     Snippet(trigger: "x", expansion: "second")]
        XCTAssertEqual(SnippetMatcher.expansion(for: "x", snippets: dupes), "first")
    }

    func testRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(snippets)
        let decoded = try JSONDecoder().decode([Snippet].self, from: data)
        XCTAssertEqual(decoded, snippets)
    }
}
