import Foundation

// Who may use the microphone and speakers right now.
//
// The unit of contention is a *session*, not a request: an agent that asks a
// question, hears the answer and asks a follow-up must not lose the microphone
// in between. So a caller claims a lease, holds it across as many speak/listen
// calls as it needs, and releases it when the conversation is over. Everyone
// else queues.
//
// Deliberately pure: the clock is a parameter and process liveness is injected,
// so every expiry, queue and cooldown rule is testable without sockets, audio
// or waiting in real time. Nothing in here touches the GUI.

struct LeaseHolder: Equatable {
    let id: String              // opaque lease token handed to the caller
    let harness: String         // "claude-code" — a label, never authentication
    let pid: pid_t              // the harness process, for liveness checks
    var grantedAt: Date
    var lastUsed: Date
}

struct QueueEntry: Equatable {
    let harness: String
    let pid: pid_t
    let joinedAt: Date
}

enum ClaimResult: Equatable {
    case granted(String)                                  // lease id
    case queued(position: Int, reason: QueueReason)
    case disabled                                         // master switch is off
}

enum QueueReason: Equatable {
    case busy(holder: String)   // someone else is mid-session
    case cooldown               // audio settling between sessions
}

enum LeaseRefusal: Error, Equatable {
    case notHolder      // lease id unknown, expired, or superseded
    case disabled
}

struct LeaseConfig {
    // Idle time before a held lease is reaped. Refreshed by every call on it,
    // so this only fires when an agent has genuinely stopped talking to us —
    // which, given `release` is the one call a crashed agent will never make,
    // is the common case rather than the edge case.
    var leaseTTL: TimeInterval = 120
    // A queued caller that has not re-claimed in this long has moved on. A
    // voice prompt that fires long after the agent wanted to ask is worse than
    // no prompt at all.
    var queueTTL: TimeInterval = 90
    // Gap between one lease ending and the next being granted. Not thermal:
    // the capture unit here can hold the input and output device past a stop
    // (see BluetoothInputGuard / VoiceProcessingGuard), and back-to-back
    // voices from different agents read as one garbled event.
    var cooldown: TimeInterval = 1.5

    static let `default` = LeaseConfig()
}

final class LeaseManager {
    private(set) var holder: LeaseHolder?
    private(set) var queue: [QueueEntry] = []
    private var freeAt: Date?          // cooldown ends
    private var counter = 0
    private let config: LeaseConfig

    // The master switch (§7.1b). Off means every call is refused with a reason
    // that tells the agent to stop asking, rather than to retry.
    var enabled: Bool

    // Injected rather than called directly so every expiry rule is testable
    // against processes that never existed. `claim` and `validate` reap on the
    // way in, so this has to be a property of the manager — a per-call
    // parameter would only cover the explicit reaps.
    private let isAlive: (pid_t) -> Bool

    init(config: LeaseConfig = .default,
         enabled: Bool = true,
         isAlive: @escaping (pid_t) -> Bool = LeaseManager.processIsAlive) {
        self.config = config
        self.enabled = enabled
        self.isAlive = isAlive
    }

    // MARK: claiming

    // Idempotent on purpose. Agents re-claim to discover whether their turn has
    // arrived, so a second call from the same harness+pid must return the same
    // lease or the same queue position — never stack up duplicate entries.
    func claim(harness: String, pid: pid_t, now: Date) -> ClaimResult {
        guard enabled else { return .disabled }
        reap(now: now)

        // The holder re-claiming gets its own lease back.
        if let holder, holder.harness == harness, holder.pid == pid {
            touch(now: now)
            return .granted(holder.id)
        }

        // Someone else is mid-session.
        if let current = holder {
            return .queued(position: enqueue(harness: harness, pid: pid, now: now),
                           reason: .busy(holder: current.harness))
        }

        // Free, but the audio is still settling from the last session.
        if let freeAt, now < freeAt {
            return .queued(position: enqueue(harness: harness, pid: pid, now: now),
                           reason: .cooldown)
        }

        // Free — but only the longest waiter may take it. Granting to whoever
        // asks first would starve an agent that has been queued the whole time,
        // which is the entire reason the queue is ordered. The lease simply
        // stays idle until the leader comes back for it, or until its queue TTL
        // expires and the next in line becomes the leader.
        if let leader = queue.first, !(leader.harness == harness && leader.pid == pid) {
            return .queued(position: enqueue(harness: harness, pid: pid, now: now),
                           reason: .busy(holder: leader.harness))
        }

        queue.removeAll { $0.harness == harness && $0.pid == pid }
        return .granted(grant(harness: harness, pid: pid, now: now))
    }

    // Only the holder may act. Every accepted call refreshes the TTL — using
    // the lease is the heartbeat, so an agent mid-conversation never has to
    // send one explicitly.
    @discardableResult
    func validate(lease id: String, now: Date) -> Result<LeaseHolder, LeaseRefusal> {
        guard enabled else { return .failure(.disabled) }
        reap(now: now)
        guard let holder, holder.id == id else { return .failure(.notHolder) }
        touch(now: now)
        return .success(holder)
    }

    // Releasing starts the cooldown; the next caller is granted after it.
    // Unknown or stale ids are not an error — a crashed agent's retry, or a
    // release after we already reaped it, should be a no-op rather than a
    // failure the agent has to reason about.
    func release(lease id: String, now: Date) {
        guard let holder, holder.id == id else { return }
        self.holder = nil
        freeAt = now.addingTimeInterval(config.cooldown)
        reap(now: now)
    }

    // The user pulling the plug from the menu bar. Unlike `release`, this does
    // not care who is holding it — when automation gets stuck, the person
    // watching should not have to wait out a timeout they cannot see.
    func forceRelease(now: Date) {
        guard holder != nil else { return }
        holder = nil
        freeAt = now.addingTimeInterval(config.cooldown)
    }

    // Turning the feature off drops everything: the holder loses the mic and
    // the queue is discarded, because every one of those callers is about to be
    // told `disabled` anyway.
    func disable() {
        enabled = false
        holder = nil
        queue.removeAll()
        freeAt = nil
    }

    // MARK: expiry

    // A dead holder is reaped immediately rather than waiting out the TTL: the
    // lease outlives its connection by design (the CLI exits between calls),
    // which is exactly what makes it leakable.
    func reap(now: Date) {
        if let current = holder {
            if now.timeIntervalSince(current.lastUsed) >= config.leaseTTL || !isAlive(current.pid) {
                holder = nil
                freeAt = now.addingTimeInterval(config.cooldown)
            }
        }
        queue.removeAll { entry in
            now.timeIntervalSince(entry.joinedAt) >= config.queueTTL || !isAlive(entry.pid)
        }
        if let at = freeAt, now >= at { freeAt = nil }
    }

    static func processIsAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        // Signal 0 checks for existence without delivering anything. EPERM
        // means it exists and belongs to someone else, which still counts.
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: internals

    private func grant(harness: String, pid: pid_t, now: Date) -> String {
        counter += 1
        let id = "L\(counter)-\(UInt32.random(in: 0..<UInt32.max))"
        holder = LeaseHolder(id: id, harness: harness, pid: pid, grantedAt: now, lastUsed: now)
        freeAt = nil
        return id
    }

    private func touch(now: Date) {
        holder?.lastUsed = now
    }

    // Returns the caller's 1-based place in line. Joining is idempotent: agents
    // re-claim to discover whether their turn has come, and each of those calls
    // must return the same position rather than append a duplicate.
    @discardableResult
    private func enqueue(harness: String, pid: pid_t, now: Date) -> Int {
        if let existing = queue.firstIndex(where: { $0.harness == harness && $0.pid == pid }) {
            return existing + 1
        }
        queue.append(QueueEntry(harness: harness, pid: pid, joinedAt: now))
        return queue.count
    }
}
