import Foundation

// Why the bridge is not listening, written where the CLI can read it.
//
// Without this, "no socket" is ambiguous in the worst possible direction. The
// client infers the feature is switched off — `disabled`, the one refusal that
// means stop asking permanently — when the truth may be that the gate is on
// and BridgeServer.start() threw. An agent then gives up for good over a
// recoverable fault, and the user is never told, because a .app's stderr goes
// nowhere anybody looks.
//
// A file rather than a socket on purpose: the whole failure being described is
// that we could not open a socket.
enum BridgeStartFailure {
    static var url: URL { AppPaths.stateDir.appendingPathComponent("bridge.error") }

    static func record(_ error: Error) {
        AppPaths.ensureStateDir()
        try? Data(error.localizedDescription.utf8).write(to: url, options: .atomic)
    }

    // Cleared whenever the bridge is deliberately not running — a started
    // bridge and a switched-off feature must both leave no stale reason behind,
    // or the next launch inherits a fault that has been fixed.
    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    static func read(stateDir: URL) -> String? {
        let path = stateDir.appendingPathComponent("bridge.error")
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty
        else { return nil }
        return text
    }
}
