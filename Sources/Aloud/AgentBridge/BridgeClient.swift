import Foundation

// The CLI half of the agent bridge.
//
// `aloud claim/listen/speak/release` is a short-lived process with exactly one
// job: connect, say one thing, hear one thing, exit. So this is deliberately
// synchronous — there is nothing else for the process to be doing — and
// deliberately impatient. Every call an agent makes sits inside a harness
// command timeout, and a wedged app that never answers would hang the agent's
// shell command and then its whole turn. Timeouts are the point of this file
// as much as the bytes are.
//
// Nothing here decides anything. A refusal is a value that comes back over the
// socket, or — when there is no socket at all — the one refusal the client
// synthesises itself.

enum BridgeClient {
    // Matches the server's ceiling. A response is small; this only exists so a
    // confused peer cannot make the CLI allocate without bound.
    static let maxLineBytes = 1 << 20

    // "Aloud isn't running" is an ordinary answer, not an error: a user who
    // quit the app is not a bug, and the agent's correct response is to ask in
    // text (§7.1b). So there is no throwing variant of this call.
    static func send(_ request: BridgeRequest,
                     timeout: TimeInterval,
                     socketURL: URL = BridgeSocket.url) -> BridgeResponse {
        let notRunning = BridgeResponse.failure(.unavailable, "Aloud isn't running.")
        let path = socketURL.path

        guard FileManager.default.fileExists(atPath: path),
              var addr = BridgeSocketIO.makeAddress(path: path) else {
            return notRunning
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return notRunning }
        BridgeSocketIO.setCloseOnExec(fd: fd)
        BridgeSocketIO.suppressSIGPIPE(fd: fd)
        // Both directions are bounded. SO_RCVTIMEO alone would still let a
        // full send buffer block the write half forever.
        BridgeSocketIO.setTimeout(fd: fd, seconds: timeout, option: SO_RCVTIMEO)
        BridgeSocketIO.setTimeout(fd: fd, seconds: timeout, option: SO_SNDTIMEO)

        let connected = BridgeSocketIO.withSockAddr(&addr) { pointer, length in
            Darwin.connect(fd, pointer, length)
        }
        guard connected == 0 else {
            // ECONNREFUSED here is the common one: the socket file outlived the
            // process that made it. Same story for the agent either way.
            close(fd)
            return notRunning
        }

        guard let line = try? BridgeCodec.encode(request) else {
            close(fd)
            return .failure(.badRequest, "Couldn't encode that request.")
        }

        guard BridgeSocketIO.writeAll(fd: fd, data: line) else {
            close(fd)
            return notRunning
        }

        // SO_RCVTIMEO bounds each individual recv, not the exchange, so a peer
        // that dribbles a byte at a time could still outlast the caller's
        // patience. The deadline bounds the whole read.
        let deadline = Date().addingTimeInterval(timeout)
        let outcome = BridgeSocketIO.readLine(fd: fd, limit: maxLineBytes, deadline: deadline)
        close(fd)

        switch outcome {
        case .line(let data):
            guard let response = try? BridgeCodec.decode(BridgeResponse.self, from: data) else {
                // A running app that speaks a protocol this CLI cannot read is
                // unusable rather than misbehaving — most likely a stale binary
                // talking to a newer app, or the reverse.
                return .failure(.unavailable, "Aloud sent a reply this version couldn't read.")
            }
            return response

        case .timedOut:
            // Not `.timeout`: that refusal means the *user* didn't answer, and
            // an agent should read the two very differently. This is the app
            // failing to respond at all.
            return .failure(.unavailable, "Aloud didn't respond in time.")

        case .closed, .failed, .tooLong:
            return notRunning
        }
    }
}
