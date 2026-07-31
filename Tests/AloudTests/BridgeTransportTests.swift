import XCTest
@testable import Aloud

// The socket is the only way an agent can reach the microphone, so its failure
// modes are security-relevant rather than merely annoying: a socket left
// world-readable, a stale file that blocks startup forever, a peer that can
// make the GUI allocate without bound, a SIGPIPE that takes the app down when
// an agent's shell command times out mid-write.
//
// Every test here drives a real AF_UNIX socket in a temp dir rather than a
// mock. Mocking the transport would test nothing that has ever gone wrong.
final class BridgeTransportTests: XCTestCase {
    private var tempDir: URL!
    private var socketURL: URL!
    private var server: BridgeServer?

    override func setUp() {
        super.setUp()
        // sockaddr_un.sun_path holds 104 bytes and NSTemporaryDirectory() is
        // already ~50 of them on macOS, so the names here are kept short on
        // purpose — a longer path fails to bind rather than truncating loudly.
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ab\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        socketURL = tempDir.appendingPathComponent("b.sock")
    }

    override func tearDown() {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: helpers

    // Test-local mutable state has to cross into a @Sendable handler running on
    // a background queue, which is exactly what this exists for.
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        var current: T { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: T) { lock.lock(); defer { lock.unlock() }; value = newValue }
    }

    // Most tests don't care who the peer is, so the helper takes the
    // request-only shape and drops the identity. testPeerIdentity… uses the
    // full handler directly.
    @discardableResult
    private func startServer(maxLineBytes: Int = BridgeServer.defaultMaxLineBytes,
                             handler: (@Sendable (BridgeRequest) async -> BridgeResponse)? = nil)
        throws -> BridgeServer {
        let server = BridgeServer(socketURL: socketURL, maxLineBytes: maxLineBytes)
        if let handler { server.handler = { request, _ in await handler(request) } }
        try server.start()
        self.server = server
        return server
    }

    // The --harness flag is a label any local process can set. The indicator
    // says "Claude Code is listening", so that name has to be corroborated
    // against something the caller cannot forge — the kernel's view of who
    // actually connected.
    func testPeerIdentityIsReadFromTheKernelNotTheRequest() throws {
        let seen = Box<BridgeServer.PeerIdentity?>(BridgeServer.PeerIdentity?.none)
        let server = BridgeServer(socketURL: socketURL)
        server.handler = { _, peer in
            seen.set(peer)
            return BridgeResponse.success()
        }
        try server.start()
        self.server = server

        var claim = request(.claim)
        claim.harness = "definitely-not-who-i-am"
        claim.pid = 999_999                     // a pid the caller made up
        _ = BridgeClient.send(claim, timeout: 5, socketURL: socketURL)

        let peer = try XCTUnwrap(seen.current)
        XCTAssertTrue(peer.isKnown, "the kernel should identify a local peer")
        XCTAssertEqual(peer.pid, getpid(), "tests connect to themselves, so the peer is this process")
        XCTAssertNotEqual(peer.pid, claim.pid, "the self-reported pid must not be what we trust")
        XCTAssertNotNil(peer.name)
    }

    private func request(_ op: BridgeOperation = .status) -> BridgeRequest {
        BridgeRequest(op: op, harness: "claude-code", pid: 4242)
    }

    // A hand-rolled client, so tests can send things BridgeClient would never
    // send: half a line, a line that never ends, bytes that are not JSON.
    private func rawExchange(chunks: [Data],
                             pauseBetweenChunks: TimeInterval = 0,
                             readReply: Bool = true,
                             ignoreWriteFailure: Bool = false) throws -> BridgeResponse? {
        guard var addr = BridgeSocketIO.makeAddress(path: socketURL.path) else {
            XCTFail("socket path too long for sockaddr_un")
            return nil
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        BridgeSocketIO.suppressSIGPIPE(fd: fd)
        BridgeSocketIO.setTimeout(fd: fd, seconds: 5, option: SO_RCVTIMEO)
        BridgeSocketIO.setTimeout(fd: fd, seconds: 5, option: SO_SNDTIMEO)
        let connected = BridgeSocketIO.withSockAddr(&addr) { pointer, length in
            Darwin.connect(fd, pointer, length)
        }
        guard connected == 0 else {
            close(fd)
            XCTFail("connect failed: \(errno)")
            return nil
        }

        for (index, chunk) in chunks.enumerated() {
            let wrote = BridgeSocketIO.writeAll(fd: fd, data: chunk)
            if !wrote && !ignoreWriteFailure {
                close(fd)
                XCTFail("write \(index) failed")
                return nil
            }
            if !wrote { break }
            if pauseBetweenChunks > 0 { Thread.sleep(forTimeInterval: pauseBetweenChunks) }
        }

        guard readReply else { close(fd); return nil }

        let outcome = BridgeSocketIO.readLine(fd: fd, limit: 1 << 20,
                                              deadline: Date().addingTimeInterval(5))
        close(fd)
        guard case .line(let data) = outcome else {
            XCTFail("expected a reply line, got \(outcome)")
            return nil
        }
        return try BridgeCodec.decode(BridgeResponse.self, from: data)
    }

    // MARK: round trip

    // The base case, end to end over a real socket: the request the CLI encodes
    // is the request the handler sees, and the handler's answer is what the CLI
    // decodes. Everything else in this file is a failure of this.
    func testRoundTripDeliversTheRequestAndReturnsTheResponse() throws {
        let seen = Box<BridgeRequest?>(nil)
        try startServer { req in
            seen.set(req)
            var response = BridgeResponse.success()
            response.lease = "L1"
            response.text = "heard you"
            return response
        }

        var outbound = request(.listen)
        outbound.lease = "L1"
        outbound.mode = .blocking
        let response = BridgeClient.send(outbound, timeout: 5, socketURL: socketURL)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.lease, "L1")
        XCTAssertEqual(response.text, "heard you")
        XCTAssertEqual(seen.current?.op, .listen)
        XCTAssertEqual(seen.current?.harness, "claude-code")
        XCTAssertEqual(seen.current?.pid, 4242)
        XCTAssertEqual(seen.current?.mode, .blocking)
    }

    // A handler that suspends is the normal case, not the exotic one: `listen`
    // waits for a person to finish a sentence. The connection has to survive
    // the await rather than being answered on whatever thread read the bytes.
    func testHandlerMayAwaitBeforeAnswering() throws {
        try startServer { _ in
            try? await Task.sleep(nanoseconds: 150_000_000)
            var response = BridgeResponse.success()
            response.text = "answered late"
            return response
        }

        let response = BridgeClient.send(request(.listen), timeout: 5, socketURL: socketURL)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.text, "answered late")
    }

    // Several agents can have commands in flight at once, and one slow `listen`
    // must not queue up behind another.
    func testConcurrentConnectionsAreServedIndependently() throws {
        try startServer { req in
            var response = BridgeResponse.success()
            response.text = req.text
            return response
        }

        let finished = expectation(description: "all callers answered")
        finished.expectedFulfillmentCount = 8
        let url = socketURL!
        for index in 0..<8 {
            DispatchQueue.global().async {
                var outbound = BridgeRequest(op: .speak, harness: "codex", pid: 1)
                outbound.text = "call-\(index)"
                let response = BridgeClient.send(outbound, timeout: 10, socketURL: url)
                XCTAssertTrue(response.ok)
                XCTAssertEqual(response.text, "call-\(index)")
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 20)
    }

    // MARK: malformed input

    // Anything on the machine can connect, including things that are not the
    // CLI at all. Garbage must come back as a refusal the agent can read, and
    // must not take the server with it.
    func testMalformedJsonIsRefusedAndTheServerKeepsServing() throws {
        try startServer { _ in .success() }

        var junk = Data("this is not json at all".utf8)
        junk.append(0x0A)
        let refusal = try rawExchange(chunks: [junk])
        XCTAssertEqual(refusal?.ok, false)
        XCTAssertEqual(refusal?.reason, .badRequest)

        // The next caller is unaffected — a bad line must not leak the listener
        // or the accept loop.
        let good = BridgeClient.send(request(), timeout: 5, socketURL: socketURL)
        XCTAssertTrue(good.ok)
    }

    // Valid JSON that is the wrong shape is the same class of problem: a stale
    // CLI, or something else entirely, speaking on our socket.
    func testWellFormedJsonWithTheWrongShapeIsAlsoBadRequest() throws {
        try startServer { _ in .success() }
        var line = Data(#"{"hello":"world"}"#.utf8)
        line.append(0x0A)
        let refusal = try rawExchange(chunks: [line])
        XCTAssertEqual(refusal?.reason, .badRequest)
    }

    // MARK: the app isn't running

    // The commonest outcome in the field, and deliberately not an error: the
    // user quit Aloud. The agent's job is to ask in text, so it needs a refusal
    // rather than a thrown error or a hang.
    func testClientReportsUnavailableWhenNothingIsListening() {
        let response = BridgeClient.send(request(), timeout: 1, socketURL: socketURL)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.reason, .unavailable)
    }

    // A crash leaves the socket file behind. `connect` then fails with
    // ECONNREFUSED rather than "no such file", and the agent must be told the
    // same thing either way.
    func testClientReportsUnavailableForAStaleSocketFileWithNobodyBehindIt() throws {
        let server = try startServer { _ in .success() }
        server.stop()
        // Recreate the corpse stop() correctly removed.
        FileManager.default.createFile(atPath: socketURL.path, contents: Data())

        let response = BridgeClient.send(request(), timeout: 1, socketURL: socketURL)
        XCTAssertEqual(response.reason, .unavailable)
    }

    // MARK: partial reads

    // A socket is a byte stream: one send() on the CLI side is not one recv()
    // here, and a long request genuinely does arrive in pieces. Reassembling
    // the line is the single most likely thing to be got wrong.
    func testARequestSplitAcrossWritesIsReassembled() throws {
        let seen = Box<BridgeRequest?>(nil)
        try startServer { req in
            seen.set(req)
            return .success()
        }

        var outbound = request(.speak)
        outbound.text = String(repeating: "the migration test is failing. ", count: 40)
        let line = try BridgeCodec.encode(outbound)

        // Three writes, with a pause between each, so the server is guaranteed
        // to see the line incomplete at least twice.
        let third = line.count / 3
        let chunks = [
            line.subdata(in: 0..<third),
            line.subdata(in: third..<(third * 2)),
            line.subdata(in: (third * 2)..<line.count),
        ]
        let response = try rawExchange(chunks: chunks, pauseBetweenChunks: 0.05)
        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(seen.current?.text, outbound.text)
    }

    // One byte at a time is the pathological version of the same thing.
    func testARequestDribbledByteByByteIsReassembled() throws {
        try startServer { req in
            var response = BridgeResponse.success()
            response.text = req.text
            return response
        }
        var outbound = request(.speak)
        outbound.text = "one byte at a time"
        let line = try BridgeCodec.encode(outbound)
        let chunks = line.map { Data([$0]) }

        let response = try rawExchange(chunks: chunks)
        XCTAssertEqual(response?.text, "one byte at a time")
    }

    // MARK: oversized input

    // A peer that never sends a newline would otherwise make the GUI allocate
    // until it dies. The cap turns that into a refusal.
    func testAnOversizedLineIsRefusedInsteadOfGrowingUnbounded() throws {
        try startServer(maxLineBytes: 2048) { _ in .success() }

        // No newline anywhere: as far as the server can tell, the line simply
        // never ends.
        let flood = Data(repeating: 0x41, count: 16_384)
        let response = try rawExchange(chunks: [flood], ignoreWriteFailure: true)
        XCTAssertEqual(response?.ok, false)
        XCTAssertEqual(response?.reason, .badRequest)

        // And the server is still there afterwards.
        let good = BridgeClient.send(request(), timeout: 5, socketURL: socketURL)
        XCTAssertTrue(good.ok)
    }

    // A request comfortably under the cap must still be accepted — the ceiling
    // is a guard rail, not a budget agents have to think about.
    func testALargeButLegalRequestIsAccepted() throws {
        try startServer { req in
            var response = BridgeResponse.success()
            response.text = req.text
            return response
        }
        var outbound = request(.speak)
        outbound.text = String(repeating: "a", count: 100_000)
        let response = BridgeClient.send(outbound, timeout: 10, socketURL: socketURL)
        XCTAssertEqual(response.text?.count, 100_000)
    }

    // MARK: no handler

    // The transport comes up before the policy is wired to it. From the agent's
    // side that is indistinguishable from the app not running, and it must not
    // be a hang or a crash.
    func testMissingHandlerIsReportedAsUnavailable() throws {
        try startServer(handler: nil)
        let response = BridgeClient.send(request(), timeout: 5, socketURL: socketURL)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.reason, .unavailable)
    }

    // MARK: the socket file itself

    // 0600 is the actual access control on the microphone here — there is no
    // token in a CLI design (§7.1), so the file mode is what stops another
    // account on the machine from opening the mic.
    func testSocketIsCreatedUserOnly() throws {
        try startServer { _ in .success() }
        let attributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertEqual(mode, 0o600, "the bridge socket must not be reachable by anyone else")
    }

    // A socket file with no listener behind it makes the next run's bind() fail
    // with EADDRINUSE forever, so stop() has to unlink and start() has to
    // tolerate one that was left behind by a crash.
    func testStopUnlinksTheSocketAndAStaleFileDoesNotBlockAFreshStart() throws {
        let first = try startServer { _ in .success() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
        first.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))

        // Simulate the crash case: the file is there, nobody is behind it.
        FileManager.default.createFile(atPath: socketURL.path, contents: Data())
        let second = try startServer { _ in .success() }
        XCTAssertTrue(second.isRunning)
        XCTAssertTrue(BridgeClient.send(request(), timeout: 5, socketURL: socketURL).ok)
    }

    // Two Aloud processes must not both think they are serving. Stealing a live
    // socket would silently split agent traffic between them.
    func testStartRefusesWhenAnotherServerIsAlreadyListening() throws {
        try startServer { _ in .success() }
        let intruder = BridgeServer(socketURL: socketURL)
        XCTAssertThrowsError(try intruder.start()) { error in
            XCTAssertEqual(error as? BridgeServerError, .alreadyRunning)
        }
        // The original is untouched.
        XCTAssertTrue(BridgeClient.send(request(), timeout: 5, socketURL: socketURL).ok)
    }

    // MARK: peers that go away

    // A harness timing out its shell command kills the CLI mid-exchange. The
    // server's write then hits a dead socket — which raises SIGPIPE and takes
    // the whole GUI down unless SO_NOSIGPIPE is set. This is the test that
    // catches that regression.
    func testAClientThatDisconnectsMidExchangeDoesNotTakeTheServerDown() throws {
        try startServer { _ in
            // Long enough that the client is certainly gone before we answer.
            try? await Task.sleep(nanoseconds: 250_000_000)
            return .success()
        }

        let line = try BridgeCodec.encode(request(.listen))
        _ = try rawExchange(chunks: [line], readReply: false)
        Thread.sleep(forTimeInterval: 0.4)

        let response = BridgeClient.send(request(), timeout: 5, socketURL: socketURL)
        XCTAssertTrue(response.ok, "a vanished client must not be able to kill the bridge")
    }

    // Connecting and saying nothing is what a probe does. It must not consume a
    // response, leak the connection, or reach the handler.
    func testAConnectionThatSaysNothingIsDroppedWithoutReachingTheHandler() throws {
        let calls = Box(0)
        try startServer { _ in
            calls.set(calls.current + 1)
            return .success()
        }

        _ = try rawExchange(chunks: [], readReply: false)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(calls.current, 0)

        XCTAssertTrue(BridgeClient.send(request(), timeout: 5, socketURL: socketURL).ok)
        XCTAssertEqual(calls.current, 1)
    }
}
