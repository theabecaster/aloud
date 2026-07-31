import Foundation

// The transport half of the agent bridge: a Unix domain socket in the running
// GUI process that the short-lived `aloud` CLI connects to.
//
// Deliberately dumb. It moves bytes and nothing else — no leases, no consent,
// no audio, no policy of any kind. Everything that decides *whether* a request
// is allowed lives behind the injected `handler`, so this file can be reasoned
// about (and tested) purely as plumbing.
//
// Two hard rules from docs/agent-voice-bridge.md §7.8 that this file exists to
// keep: it is AF_UNIX only — never a TCP or localhost port — and the socket
// file is 0600 in the user-only state dir, because a local process being able
// to open the microphone is the whole risk (§7.1).

// MARK: - low-level socket plumbing

// Shared by the server and by BridgeClient. Kept as free functions over raw
// file descriptors rather than a wrapper type: the CLI side runs before almost
// anything else in the process is set up, and both sides want the same
// timeout / partial-read / EINTR handling.
enum BridgeSocketIO {
    // A Unix socket path lives in a fixed 104-byte field. Longer paths do not
    // fail at bind() with something readable — they silently truncate — so the
    // length is checked up front.
    static func makeAddress(path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    static func withSockAddr<T>(_ addr: inout sockaddr_un,
                                _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    // Darwin has no MSG_NOSIGNAL; SO_NOSIGPIPE is the per-socket equivalent.
    // Without it a client that walks away mid-write kills the whole GUI with
    // SIGPIPE — the loudest possible failure for the least important subsystem.
    static func suppressSIGPIPE(fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setCloseOnExec(fd: Int32) {
        let flags = fcntl(fd, F_GETFD, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
    }

    static func setBlocking(fd: Int32, _ blocking: Bool) {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, blocking ? (flags & ~O_NONBLOCK) : (flags | O_NONBLOCK))
    }

    // `option` is SO_RCVTIMEO or SO_SNDTIMEO. A timeval of exactly zero means
    // "block forever", which is the opposite of what every caller here wants,
    // so tiny values are floored rather than rounded away.
    static func setTimeout(fd: Int32, seconds: TimeInterval, option: Int32) {
        let clamped = max(0.001, seconds)
        var tv = timeval(tv_sec: __darwin_time_t(clamped),
                         tv_usec: __darwin_suseconds_t((clamped - clamped.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    enum ReadOutcome {
        case line(Data)     // a complete line, newline stripped
        case tooLong        // the peer is not speaking our protocol, or is hostile
        case closed         // peer went away before saying anything
        case timedOut
        case failed
    }

    // NDJSON is a stream protocol: one `send` on the far side is not one
    // `recv` here. The line is reassembled across reads, and the running total
    // is capped so a peer that never sends a newline cannot make us allocate
    // until the app dies.
    static func readLine(fd: Int32, limit: Int, deadline: Date? = nil) -> ReadOutcome {
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let deadline, Date() >= deadline { return .timedOut }
            let read = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if read > 0 {
                if let newline = chunk[0..<read].firstIndex(of: 0x0A) {
                    line.append(contentsOf: chunk[0..<newline])
                    return .line(line)
                }
                line.append(contentsOf: chunk[0..<read])
                if line.count > limit { return .tooLong }
                continue
            }
            if read == 0 {
                // EOF. A peer that closed cleanly after a newline-less payload
                // still said something complete enough to answer.
                return line.isEmpty ? .closed : .line(line)
            }
            let code = errno
            if code == EINTR { continue }
            if code == EAGAIN || code == EWOULDBLOCK { return .timedOut }
            return .failed
        }
    }

    @discardableResult
    static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let written = send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if written > 0 {
                    sent += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                return false    // peer is gone; not our problem, and not fatal
            }
            return true
        }
    }

    // Closing a socket that still has unread bytes queued makes the kernel send
    // an RST, which can throw away the response we *just* wrote. That is
    // exactly the shape of the oversized-request case — we stop reading while
    // the peer is still sending — so the last thing before close is a short,
    // bounded drain.
    static func drainAndClose(fd: Int32, budget: TimeInterval = 0.2, cap: Int = 1 << 18) {
        shutdown(fd, SHUT_WR)
        setTimeout(fd: fd, seconds: budget, option: SO_RCVTIMEO)
        var scratch = [UInt8](repeating: 0, count: 4096)
        var drained = 0
        let deadline = Date().addingTimeInterval(budget)
        while drained < cap && Date() < deadline {
            let read = scratch.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if read > 0 {
                drained += read
                continue
            }
            if read < 0 && errno == EINTR { continue }
            break
        }
        close(fd)
    }

    // Is somebody actually listening on this path, or is it a corpse from a
    // previous run? Cheapest possible answer: try to connect.
    static func isLive(path: String) -> Bool {
        guard var addr = makeAddress(path: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        setBlocking(fd: fd, false)
        let result = withSockAddr(&addr) { pointer, length in
            Darwin.connect(fd, pointer, length)
        }
        return result == 0
    }
}

// MARK: - errors

enum BridgeServerError: Error, Equatable {
    case alreadyRunning         // another Aloud already owns this socket
    case pathTooLong(String)    // sockaddr_un.sun_path is only 104 bytes
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}

// MARK: - server

final class BridgeServer: @unchecked Sendable {
    // Every decision the bridge makes lives behind this. The server contains no
    // policy: it decodes, calls out, encodes the answer back. `@Sendable`
    // because the call happens on a background queue, never the main thread.
    typealias Handler = @Sendable (BridgeRequest) async -> BridgeResponse

    // A request is a few hundred bytes. A megabyte is orders of magnitude of
    // headroom and still a hard ceiling on what one connection can make us
    // allocate — the point is that the number exists, not what it is.
    static let defaultMaxLineBytes = 1 << 20

    let socketURL: URL
    let maxLineBytes: Int
    // How long a connected-but-silent peer may hold a connection open. Bounded
    // so a wedged CLI cannot pin a worker thread indefinitely.
    var readTimeout: TimeInterval = 5

    private let lock = NSLock()
    private var storedHandler: Handler?
    private var listenerFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    // Accepts land on a serial queue (one place decides what to do with new
    // connections); each connection is then served on a concurrent queue so a
    // slow handler cannot stall the next caller. Neither is the main queue —
    // the GUI must never wait on an agent.
    private let acceptQueue = DispatchQueue(label: "com.abrahamgonzalez.aloud.bridge.accept",
                                            qos: .userInitiated)
    private let connectionQueue = DispatchQueue(label: "com.abrahamgonzalez.aloud.bridge.conn",
                                                qos: .userInitiated,
                                                attributes: .concurrent)

    var handler: Handler? {
        get { lock.lock(); defer { lock.unlock() }; return storedHandler }
        set { lock.lock(); defer { lock.unlock() }; storedHandler = newValue }
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return listenerFD >= 0
    }

    init(socketURL: URL = BridgeSocket.url, maxLineBytes: Int = BridgeServer.defaultMaxLineBytes) {
        self.socketURL = socketURL
        self.maxLineBytes = maxLineBytes
    }

    deinit { stop() }

    // MARK: lifecycle

    func start() throws {
        lock.lock()
        guard listenerFD < 0 else {
            lock.unlock()
            throw BridgeServerError.alreadyRunning
        }
        lock.unlock()

        let path = socketURL.path
        guard var addr = BridgeSocketIO.makeAddress(path: path) else {
            throw BridgeServerError.pathTooLong(path)
        }

        // The state dir normally exists already; when it does not, create it
        // user-only so the socket is never briefly reachable through a
        // world-readable parent.
        let parent = socketURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try? FileManager.default.createDirectory(at: parent,
                                                     withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }

        // A crash leaves the socket file behind and bind() would fail with
        // EADDRINUSE forever. Unlinking is safe *only* once we know nobody is
        // behind it — otherwise we would silently steal a live instance's
        // socket and both would think they were serving.
        if FileManager.default.fileExists(atPath: path) {
            if BridgeSocketIO.isLive(path: path) { throw BridgeServerError.alreadyRunning }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeServerError.socketFailed(errno) }
        BridgeSocketIO.setCloseOnExec(fd: fd)
        BridgeSocketIO.suppressSIGPIPE(fd: fd)
        BridgeSocketIO.setBlocking(fd: fd, false)

        // bind() applies the umask, so the mode is right the moment the node
        // appears rather than a chmod later — there is no window where the
        // socket is group- or world-connectable. The chmod afterwards is belt
        // and braces for an inherited umask that already cleared owner bits.
        let previousMask = umask(0o177)
        let bound = BridgeSocketIO.withSockAddr(&addr) { pointer, length in
            Darwin.bind(fd, pointer, length)
        }
        umask(previousMask)
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw BridgeServerError.bindFailed(code)
        }
        chmod(path, 0o600)

        guard Darwin.listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw BridgeServerError.listenFailed(code)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(listener: fd) }
        source.setCancelHandler { close(fd) }

        lock.lock()
        listenerFD = fd
        acceptSource = source
        lock.unlock()

        source.resume()
    }

    // Must leave nothing behind: a socket file with no listener makes the next
    // run's bind() fail, and the CLI would report "Aloud isn't running" against
    // an app that is.
    func stop() {
        lock.lock()
        let source = acceptSource
        let fd = listenerFD
        acceptSource = nil
        listenerFD = -1
        lock.unlock()

        if let source {
            source.cancel()             // the cancel handler owns the close
        } else if fd >= 0 {
            close(fd)
        }
        unlink(socketURL.path)
    }

    // MARK: accepting

    private func acceptPending(listener: Int32) {
        // The listener is non-blocking, so this drains every connection the
        // kernel has queued and stops on EAGAIN rather than assuming one
        // readable event means exactly one connection.
        while true {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 {
                let code = errno
                if code == EINTR { continue }
                return                  // EAGAIN / EWOULDBLOCK / listener closed
            }
            BridgeSocketIO.setCloseOnExec(fd: client)
            BridgeSocketIO.suppressSIGPIPE(fd: client)
            // BSD accept() inherits the listener's file status flags, so this
            // has to be put back explicitly or every recv returns EAGAIN.
            BridgeSocketIO.setBlocking(fd: client, true)
            BridgeSocketIO.setTimeout(fd: client, seconds: readTimeout, option: SO_RCVTIMEO)
            BridgeSocketIO.setTimeout(fd: client, seconds: readTimeout, option: SO_SNDTIMEO)
            serve(client)
        }
    }

    // MARK: serving one request

    private func serve(_ fd: Int32) {
        let limit = maxLineBytes
        connectionQueue.async { [weak self] in
            guard let self else { close(fd); return }

            switch BridgeSocketIO.readLine(fd: fd, limit: limit) {
            case .closed:
                // Somebody opened a connection and said nothing. Nothing to
                // answer, nothing to log.
                close(fd)

            case .failed:
                close(fd)

            case .timedOut:
                self.reply(fd: fd, response: .failure(.badRequest, "No request arrived."))

            case .tooLong:
                self.reply(fd: fd,
                           response: .failure(.badRequest,
                                              "Request exceeded \(limit) bytes."))

            case .line(let line):
                guard let request = try? BridgeCodec.decode(BridgeRequest.self, from: line) else {
                    self.reply(fd: fd, response: .failure(.badRequest, "Couldn't read that request."))
                    return
                }
                guard let handler = self.handler else {
                    // Transport is up but nothing is wired to it yet — from the
                    // agent's side that is indistinguishable from the app not
                    // running, and `unavailable` is the refusal that says so.
                    self.reply(fd: fd,
                               response: .failure(.unavailable, "Aloud isn't ready for agent requests."))
                    return
                }
                // The handler is async and may take as long as a person takes
                // to answer a question, so the connection is parked in a Task
                // and the write hops back to the I/O queue afterwards. Nothing
                // blocks waiting on it.
                Task {
                    let response = await handler(request)
                    self.connectionQueue.async { self.reply(fd: fd, response: response) }
                }
            }
        }
    }

    private func reply(fd: Int32, response: BridgeResponse) {
        // Encoding a BridgeResponse cannot realistically fail, but a crash here
        // would take the GUI with it, so the fallback is a hand-written line.
        var fallback = Data(#"{"ok":false,"reason":"badRequest","v":1}"#.utf8)
        fallback.append(0x0A)
        let data = (try? BridgeCodec.encode(response)) ?? fallback
        BridgeSocketIO.writeAll(fd: fd, data: data)
        BridgeSocketIO.drainAndClose(fd: fd)
    }
}
