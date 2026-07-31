import Foundation

// The wire contract between the `aloud` CLI and the running menu bar app.
//
// NDJSON over a Unix domain socket: one JSON object per line, request then
// response, connection closed. Not a network protocol — no TCP, no localhost
// port, ever (see docs/agent-voice-bridge.md §7.8). The socket lives in the
// user-only state dir at 0600.
//
// The CLI is a thin client: the microphone, the model and the indicator all
// live in the GUI process, and a `flock` singleton means a second process
// cannot start its own recorder anyway.

enum BridgeProtocolVersion {
    // Bumped only for changes a shipped skill file could not survive. The
    // installed instructions are written once and may be years old.
    static let current = 1
}

enum BridgeSocket {
    static var url: URL { AppPaths.stateDir.appendingPathComponent("bridge.sock") }
}

// MARK: requests

enum BridgeOperation: String, Codable {
    case claim      // take the lease, or join the queue
    case release    // give it up; starts the cooldown
    case speak      // say something out loud
    case listen     // capture and transcribe
    case status     // what can I do right now — never opens the microphone
}

struct BridgeRequest: Codable {
    var v: Int = BridgeProtocolVersion.current
    var op: BridgeOperation
    // Label only, never authentication — anything can pass any harness id.
    // It exists so the user sees something meaningful on the indicator and
    // hears the right name; access is gated by socket permissions and the
    // consent mode, never by this.
    var harness: String
    // The harness process, so an abandoned lease can be reaped the moment its
    // owner is gone rather than waiting out the TTL.
    var pid: pid_t
    var lease: String?
    var text: String?           // speak
    var mode: ListenMode?       // listen
    var wait: Double?           // listen --poll: long-poll ceiling, seconds

    enum ListenMode: String, Codable {
        case blocking   // default: capture until the speaker stops, return the final
        case start      // open a session and return immediately
        case poll       // return as soon as the transcript changes, or at `wait`
        case stop       // end the session and return the final
    }
}

// MARK: responses

// Refusals are ordinary return values, not errors. An agent that has only ever
// seen `listen` succeed will treat a thrown error as a bug and retry it, or
// stall the turn — so every "no" is a shape the skill file can teach.
enum BridgeRefusal: String, Codable {
    case disabled       // master switch is off — stop asking until told otherwise
    case denied         // the user said no to *this* request; asking later is fine
    case timeout        // nobody answered
    case queued         // someone else holds the lease
    case notHolder      // this lease expired, was reaped, or was never yours
    case unavailable    // Aloud isn't running, or has no microphone permission
    case badRequest
}

struct BridgeResponse: Codable {
    var v: Int = BridgeProtocolVersion.current
    var ok: Bool
    var reason: BridgeRefusal?
    var message: String?

    // claim
    var lease: String?
    var position: Int?
    var queuedBehind: String?      // harness name, so the agent can say who
    var retryAfter: Double?        // seconds; set for cooldown and queueing

    // listen
    var text: String?              // final transcript, or the partial while polling
    var raw: String?               // before cleanup, for agents that want verbatim
    var cleanup: Cleanup?
    var speaking: Bool?            // poll: is the user still talking
    var silentFor: Double?         // poll: seconds since speech stopped
    var session: String?           // listen --start

    // status
    var enabled: Bool?
    var voice: Voice?
    var holder: String?
    var harnesses: [String]?       // installed, so `speak` can decide whether to
                                   // name itself (§7.1c: only when >1)

    // The final text is the best cleanup this Mac can do, not always Concise:
    // the rewrite needs Apple Intelligence and Aloud targets macOS 14+. Saying
    // which one ran lets an agent decide whether to trust it as a summary or
    // treat it as a raw transcript.
    enum Cleanup: String, Codable {
        case concise    // on-device rewrite
        case basic      // deterministic polish only
        case none
    }

    enum Voice: String, Codable {
        case enhanced
        case system
    }

    static func failure(_ reason: BridgeRefusal, _ message: String) -> BridgeResponse {
        BridgeResponse(ok: false, reason: reason, message: message)
    }

    static func success() -> BridgeResponse {
        BridgeResponse(ok: true)
    }
}

// MARK: codec

// One object per line. Newline-delimited rather than length-prefixed so the
// socket can be driven by hand with `nc` when something is wrong.
enum BridgeCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }
}
