import XCTest
@testable import Aloud

// The agent verbs are the one part of Aloud whose caller is a language model
// reading a file we wrote. It types the command line out of the installed
// instructions, so a parser that mis-reads a documented form does not produce a
// bug report — it produces an agent that quietly stops using the feature.
//
// This file exists because that happened. `ask --end "<question>"` is the exact
// line the skill and the global note both teach, and the question was being
// read as `--end`'s value: the call came back "usage: …", as though no question
// had been passed, for a command line copied verbatim from our own docs.
final class CLIArgumentTests: XCTestCase {

    // The line the instructions actually teach, parsed the way the CLI parses
    // it. Written as one array rather than assembled, so it can be compared to
    // the documentation by eye.
    private let documentedAsk = [
        "ask", "--harness", "claude-code", "--owner-pid", "9021",
        "--name", "fixing tests", "--end",
        "The migration test is failing. Roll it back, or fix it forward?",
    ]

    func testTheDocumentedAskLineParsesEveryPartOfItself() {
        XCTAssertEqual(CLI.value(of: "--harness", in: documentedAsk), "claude-code")
        XCTAssertEqual(CLI.value(of: "--name", in: documentedAsk), "fixing tests")
        XCTAssertEqual(CLI.ownerProcessID(documentedAsk), 9021)
        XCTAssertTrue(documentedAsk.contains("--end"))
        XCTAssertEqual(CLI.firstPositional(after: 1, in: documentedAsk),
                       "The migration test is failing. Roll it back, or fix it forward?",
                       "the question is the positional, not --end's value")
    }

    // A switch takes no value, so the word after it belongs to whoever comes
    // next. Every switch is checked rather than just the one that broke: they
    // are all reachable on a `listen`, and the failure is silent in each case.
    func testASwitchNeverSwallowsTheWordAfterIt() {
        for flag in CLI.valuelessFlags {
            let args = ["listen", "--lease", "L1", flag, "positional"]
            XCTAssertEqual(CLI.firstPositional(after: 1, in: args), "positional",
                           "\(flag) is a switch and must not consume the next word")
            XCTAssertEqual(CLI.value(of: "--lease", in: args), "L1",
                           "\(flag) must not disturb the flags around it")
        }
    }

    // The mirror image: a flag that does expect a value must not accept a
    // switch as one. `--name --end` is a user who forgot the name, and taking
    // "--end" as the session name would put it on the indicator.
    func testAFlagExpectingAValueRefusesToTakeASwitchAsOne() {
        let args = ["ask", "--name", "--end", "hello"]
        XCTAssertNil(CLI.value(of: "--name", in: args))
        XCTAssertNil(CLI.value(of: "--nothing-here", in: args))
        XCTAssertNil(CLI.value(of: "--name", in: ["ask", "--name"]), "nothing follows it at all")
    }

    // A flag's value may be anything — spaces, punctuation, an absolute path
    // with a space in it — because it is identified by position rather than by
    // shape.
    func testAFlagsValueMayBeAnyText() {
        let args = ["speak", "--lease", "L1", "--name", "release notes",
                    "Shall I tag it — or wait for review?"]
        XCTAssertEqual(CLI.value(of: "--name", in: args), "release notes")
        XCTAssertEqual(CLI.firstPositional(after: 1, in: args),
                       "Shall I tag it — or wait for review?")
    }

    // The limitation this used to pin is gone. Skipping anything that merely
    // looked like a flag — and the word after it — made a whole class of
    // perfectly ordinary questions unreachable: "--wait or ship it?" was read
    // as a flag, skipped along with the next word, and the call came back
    // "usage:" as though no text had been passed. Only the flags that actually
    // exist are skipped now, which is the rule `value(of:)` has always used.
    func testTextBeginningWithDashesIsStillTheCallersOwnWords() {
        XCTAssertEqual(CLI.firstPositional(after: 1, in: ["speak", "--lease", "L1", "--odd"]),
                       "--odd")
        XCTAssertEqual(CLI.firstPositional(after: 1,
                                           in: ["ask", "--harness", "claude-code",
                                                "--wait for review, or ship it?"]),
                       "--wait for review, or ship it?")
    }

    // The conventional escape hatch, for the one case the rule above cannot
    // cover: text that is character-for-character a flag Aloud does know.
    func testDoubleDashEndsTheOptionsAndHandsBackWhateverFollows() {
        XCTAssertEqual(CLI.firstPositional(after: 1, in: ["speak", "--lease", "L1", "--", "--wait"]),
                       "--wait")
    }

    // Every ordering the instructions could plausibly be copied into. The text
    // is documented last, but nothing stops an agent putting it first, and a
    // parser that only works in the documented order works until it doesn't.
    func testTheQuestionIsFoundWhereverItIsPut() {
        let question = "Roll it back?"
        let orderings = [
            ["ask", question, "--harness", "claude-code", "--end"],
            ["ask", "--end", "--harness", "claude-code", question],
            ["ask", "--harness", "claude-code", question, "--end"],
            ["ask", "--end", question],
        ]
        for args in orderings {
            XCTAssertEqual(CLI.firstPositional(after: 1, in: args), question,
                           "failed on \(args)")
        }
    }

    // `--hold` is the documented long-wait form, and it sits between two
    // switches in the line the instructions teach — which is exactly the
    // arrangement that broke `--end`.
    func testTheDocumentedHoldLineParsesEveryPartOfItself() {
        let args = ["ask", "--harness", "claude-code", "--owner-pid", "9021",
                    "--name", "fixing tests", "--hold", "600", "--end",
                    "Roll the migration back, or fix it forward?"]
        XCTAssertEqual(CLI.value(of: "--hold", in: args), "600")
        XCTAssertEqual(CLI.value(of: "--name", in: args), "fixing tests")
        XCTAssertEqual(CLI.firstPositional(after: 1, in: args),
                       "Roll the migration back, or fix it forward?")
    }

    // `--owner-pid` is how Aloud tells two windows of the same tool apart and
    // reaps a lease the moment its owner exits. A value it cannot parse has to
    // fall back to anonymous rather than to a pid that means something else.
    func testAnUnusableOwnerPidFallsBackToAnonymous() {
        for raw in ["0", "-3", "not-a-pid", ""] {
            XCTAssertEqual(CLI.ownerProcessID(["claim", "--owner-pid", raw]),
                           LeaseManager.noOwnerPid, "\(raw) is not a process")
        }
        XCTAssertEqual(CLI.ownerProcessID(["claim"]), LeaseManager.noOwnerPid)
    }

    // Every verb the instructions teach has to reach the agent branch of
    // `CLI.run`. The routing is driven off `BridgeOperation` now precisely
    // because a hand-kept list disagreed with it once.
    func testEveryTaughtVerbIsAKnownOperation() {
        for verb in AgentVoiceInstructions.verbs {
            XCTAssertNotNil(BridgeOperation(rawValue: verb))
        }
    }
}
