import XCTest
@testable import Aloud

// The instructions Aloud writes into every agent tool, checked against the CLI
// they describe.
//
// These are the only documentation an agent ever reads, they are written once
// into a file that may sit unread for months, and nothing about them fails
// loudly when they drift: a wrong flag makes an agent give up on the feature,
// and a wrong response shape makes it parse for a field that never comes. So
// every command line and every example payload in them is verified here rather
// than by eye.
final class AgentInstructionsTests: XCTestCase {

    private let text = AgentVoiceInstructions.body(harness: .claudeCode, command: "aloud")
    private let note = AgentVoiceInstructions.globalNote(harness: .claudeCode, command: "aloud")

    // Every `# {...}` in the instructions is a payload we claim the app sends.
    private func examples(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# {"), trimmed.hasSuffix("}") else { return nil }
            return String(trimmed.dropFirst(2))
        }
    }

    // What a response can actually contain, from the type itself — so a field
    // renamed or removed in the protocol fails here rather than in a user's
    // agent months later.
    private var responseKeys: Set<String> {
        get throws {
            var everything = BridgeResponse.success()
            everything.reason = .queued
            everything.message = "m"
            everything.lease = "L1"
            everything.position = 1
            everything.queuedBehind = "x"
            everything.retryAfter = 1
            everything.text = "t"
            everything.cleanup = .concise
            everything.speaking = true
            everything.silentFor = 1
            everything.session = "S1"
            everything.waited = 1
            everything.enabled = true
            everything.holder = "h"
            let data = try BridgeCodec.encode(everything)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return Set(object.keys)
        }
    }

    func testTheInstructionsShowSomeExamples() {
        XCTAssertGreaterThanOrEqual(examples(in: text).count, 5)
        XCTAssertEqual(examples(in: note).count, 1)
    }

    // Each example has to be a payload the app could send: real JSON, only
    // real fields, and every one of them carrying the two an agent branches on.
    func testEveryExampleIsAShapeTheAppCanActuallySend() throws {
        let known = try responseKeys
        for example in examples(in: text) + examples(in: note) {
            let data = try XCTUnwrap(example.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any],
                                       "not JSON: \(example)")
            for key in object.keys {
                XCTAssertTrue(known.contains(key),
                              "\(example) shows `\(key)`, which no response carries")
            }
            XCTAssertNotNil(object["ok"], "\(example) omits `ok`, which every response has")
            XCTAssertNotNil(object["v"], "\(example) omits `v`, which every response has")
        }
    }

    // And has to be spelled the way the app spells it. Responses go out with
    // sorted keys; an example in another order teaches an agent to expect a
    // wire format that never arrives.
    func testEveryExampleIsWrittenTheWayTheAppEncodesIt() throws {
        for example in examples(in: text) + examples(in: note) {
            let data = try XCTUnwrap(example.data(using: .utf8))
            // Round-tripped through the app's own codec, so the order compared
            // against is the order the socket really emits.
            //
            // This used to derive both sides from the same literal — a
            // JSONSerialization parse of the example against a text split of
            // the example — which only ever proved that one hand-written string
            // was alphabetical. `BridgeCodec`'s `.sortedKeys` could have been
            // deleted outright and it stayed green, while every agent reading
            // these examples was taught a wire format that no longer arrived.
            let response = try BridgeCodec.decode(BridgeResponse.self, from: data)
            let reencoded = try BridgeCodec.encode(response)
            let emitted = try XCTUnwrap(String(data: reencoded, encoding: .utf8))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            XCTAssertEqual(keyOrder(of: example), keyOrder(of: emitted),
                           "example is not in the app's own key order: \(example)")
        }
    }

    // The keys in the order they appear on the wire. Keys only, not the whole
    // string: a Double re-encoded here prints 0.4 as 0.40000000000000002, which
    // says something about JSON encoders and nothing about the instructions.
    private func keyOrder(of json: String) -> [String] {
        json
            .dropFirst().dropLast()          // the braces
            .split(separator: ",")
            .compactMap { $0.split(separator: ":").first }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
    }

    // Flags the instructions teach have to be flags the CLI reads. A typo here
    // is an agent sending a switch the parser ignores.
    func testEveryFlagTaughtIsOneTheCLIReads() {
        let known: Set<String> = ["--harness", "--owner-pid", "--name", "--lease", "--end",
                                  "--hold", "--wait", "--session", "--start", "--poll", "--stop"]
        for line in (text + note).split(separator: "\n") {
            for word in line.split(separator: " ") where word.hasPrefix("--") {
                let flag = String(word.trimmingCharacters(in: CharacterSet(charactersIn: "`,.\"")))
                // Prose wraps on a trailing backslash and quotes flags inline;
                // only check things that still look like a bare flag.
                guard flag.hasPrefix("--"), !flag.contains("\\") else { continue }
                XCTAssertTrue(known.contains(flag), "instructions teach `\(flag)`, which the CLI has no such flag for")
            }
        }
    }

    // The verbs, both ways: everything taught exists, and everything that
    // exists is taught. A verb nobody documents is one nobody uses; a verb
    // documented but absent is a command that fails in front of a user.
    func testTheVerbsTaughtAreTheVerbsThatExist() {
        for verb in BridgeOperation.allCases.map(\.rawValue) {
            XCTAssertTrue(text.contains("aloud \(verb)") || text.contains("`\(verb)`"),
                          "the instructions never mention `\(verb)`")
        }
    }

    // The limits an agent will hit. Each of these is a refusal if it guesses
    // wrong, so the number in the prose has to be the number in the code.
    func testTheLimitsQuotedAreTheLimitsEnforced() {
        XCTAssertTrue(text.contains("\(Int(AgentBridgeService.maxHold))"),
                      "the `--hold` ceiling in the prose is not \(AgentBridgeService.maxHold)")
        XCTAssertTrue(text.contains("\(Int(AgentBridgeService.maxQueueWait))"),
                      "the `claim --wait` ceiling in the prose is not \(AgentBridgeService.maxQueueWait)")
        XCTAssertTrue(text.contains("\(SessionName.maxWords) words"),
                      "the `--name` word limit is not stated as \(SessionName.maxWords)")
        XCTAssertTrue(text.contains("\(SessionName.maxCharacters) characters"),
                      "the `--name` character limit is not stated as \(SessionName.maxCharacters)")
    }

    // Every refusal an agent can receive has a row telling it what to do.
    func testEveryRefusalIsExplained() {
        for refusal in [BridgeRefusal.disabled, .denied, .timeout, .queued,
                        .notHolder, .unavailable, .badRequest] {
            XCTAssertTrue(text.contains("`\(refusal.rawValue)`"),
                          "the instructions never explain `\(refusal.rawValue)`")
        }
    }
}
