import XCTest
@testable import Aloud

// What a shipped Aloud offers the outside world, pinned.
//
// Two surfaces meet here and neither is obvious from reading one file. The CLI
// of a distributed bundle answers `--version` and the agent verbs and nothing
// else — the development verbs type into the focused app, open the microphone
// and print the user's paths, and a signed binary holding those TCC grants
// must not offer them to whatever process invokes it. And the bridge answers
// only what a caller can act on: may I ask, and is the microphone free.
//
// Both drift silently. A verb added to the operation table ships to every
// user; a field added to the status response is readable by any process that
// can open the socket. So the shapes are written down rather than assumed.
final class AgentSurfaceTests: XCTestCase {

    // Every verb here is taught by the instructions Aloud installs, and each
    // is one an agent cannot do its job without. Adding to this list widens
    // what a release exposes, so it should be a decision rather than a commit.
    func testTheAgentVerbsAreExactlyTheSupportedSurface() {
        XCTAssertEqual(Set(BridgeOperation.allCases.map(\.rawValue)),
                       ["ask", "wait", "claim", "release", "speak", "listen", "status"])
    }

    // Reading a JSON object is how the response shape is checked, because the
    // keys are what actually cross the socket — a property that is never set
    // is not exposed, whatever the type says.
    private func fields<T: Encodable>(of value: T) throws -> Set<String> {
        let data = try BridgeCodec.encode(value)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    func testStatusTellsACallerWhatItMayDoAndNothingAboutTheUser() throws {
        var status = BridgeResponse.success()
        status.enabled = true
        status.holder = "claude-code"

        let keys = try fields(of: status)
        XCTAssertEqual(keys, ["v", "ok", "enabled", "holder"])
        // The setup fields that used to ride along here. Nothing read them,
        // no installed instruction mentions them, and both describe the user's
        // machine rather than the caller's permission.
        for setupField in ["voice", "speed", "harnesses", "gender"] {
            XCTAssertFalse(keys.contains(setupField),
                           "status leaks \(setupField) — that is the user's setup, not the caller's business")
        }
    }

    // How fast and in which voice Aloud speaks is a Settings decision. An
    // agent that could read it would start reasoning about it; one that could
    // set it would be changing the user's preferences from a shell.
    func testNothingOnTheWireCarriesTheVoiceSettings() throws {
        var everything = BridgeResponse.success()
        everything.enabled = true
        everything.holder = "codex"
        everything.lease = "L1"
        everything.text = "fix it forward"
        everything.cleanup = .concise
        everything.session = "S1"
        everything.speaking = false
        everything.silentFor = 0.4
        everything.waited = 12
        everything.position = 2
        everything.queuedBehind = "cursor"
        everything.retryAfter = 3
        everything.reason = .queued
        everything.message = "busy"

        let response = try fields(of: everything)
        for setting in ["voice", "speed", "gender", "rate"] {
            XCTAssertFalse(response.contains(setting), "response exposes \(setting)")
        }

        var request = BridgeRequest(op: .speak, harness: "claude-code", pid: 1)
        request.text = "hello"
        request.name = "fixing tests"
        request.lease = "L1"
        let asked = try fields(of: request)
        for setting in ["voice", "speed", "gender", "rate"] {
            XCTAssertFalse(asked.contains(setting),
                           "a caller can set \(setting) — that is the user's setting to make")
        }
    }
}
