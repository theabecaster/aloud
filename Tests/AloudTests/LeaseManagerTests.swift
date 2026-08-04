import XCTest
@testable import Aloud

// The lease is what keeps one agent's conversation intact while another waits.
// Its failure modes are all invisible in normal use and painful in the field —
// a leaked lease locks the microphone for everyone, a duplicated queue entry
// starves someone forever — so they are pinned here rather than discovered.
final class LeaseManagerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    // Liveness is injected everywhere: the pids in these tests are made up, and
    // with the real check pid 2 simply does not exist on this machine, so every
    // queued entry would be reaped before the assertion ran.
    // `noOwnerPid` counts as alive, exactly as the real check does: there is no
    // process to watch, so such a lease is governed by its TTL alone. A fake
    // that called it dead would reap every anonymous holder instantly and
    // quietly invert what these tests appear to prove.
    private func manager(_ config: LeaseConfig = .default,
                         alive: Set<pid_t> = [1, 2, 3, 42]) -> LeaseManager {
        LeaseManager(config: config,
                     isAlive: { $0 == LeaseManager.noOwnerPid || alive.contains($0) })
    }

    // MARK: granting and holding

    func testFirstClaimIsGranted() {
        let m = manager()
        guard case .granted(let id) = m.claim(harness: "claude-code", pid: 1, name: "fixing tests", ownerVerified: true, now: t0) else {
            return XCTFail("first claim should be granted")
        }
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(m.holder?.harness, "claude-code")
    }

    func testSecondHarnessQueuesBehindTheHolder() {
        let m = manager()
        _ = m.claim(harness: "claude-code", pid: 1, name: "fixing tests", ownerVerified: true, now: t0)
        let result = m.claim(harness: "codex", pid: 2, name: "fixing tests", ownerVerified: true, now: t0)
        XCTAssertEqual(result, .queued(position: 1, reason: .busy(holder: "claude-code")))
    }

    // Agents re-claim to find out whether their turn has come. That must not
    // hand them a second lease, nor a second place in the queue.
    func testReclaimingIsIdempotentForHolderAndQueue() {
        let m = manager()
        guard case .granted(let first) = m.claim(harness: "claude-code", pid: 1, name: "fixing tests", ownerVerified: true, now: t0) else {
            return XCTFail("expected grant")
        }
        guard case .granted(let again) = m.claim(harness: "claude-code", pid: 1, name: "fixing tests", ownerVerified: true, now: t0) else {
            return XCTFail("holder re-claiming should get its own lease back")
        }
        XCTAssertEqual(first, again)

        _ = m.claim(harness: "codex", pid: 2, name: "fixing tests", ownerVerified: true, now: t0)
        _ = m.claim(harness: "codex", pid: 2, name: "fixing tests", ownerVerified: true, now: t0)
        _ = m.claim(harness: "codex", pid: 2, name: "fixing tests", ownerVerified: true, now: t0)
        XCTAssertEqual(m.queue.count, 1, "re-claiming must not stack duplicate queue entries")
    }

    // Two sessions of one tool are two claimants, not one.
    //
    // The harness id is a label — anything may pass `--harness claude-code` —
    // so the lease recognises its holder by the long-lived process the caller
    // names. A caller that cannot name one is anonymous, and every anonymous
    // caller looks identical: matching them to the holder handed the second
    // session the first's lease, and with it the power to speak, listen and
    // release on somebody else's conversation. Seen on the running app: a
    // second codex claim came back with the first's lease id.
    func testAnonymousSecondSessionQueuesInsteadOfInheritingTheLease() {
        let m = manager()
        guard case .granted(let first) = m.claim(harness: "claude-code", pid: LeaseManager.noOwnerPid,
                                                 name: "fixing tests", ownerVerified: true,
                                                 now: t0) else {
            return XCTFail("expected grant")
        }
        let second = m.claim(harness: "claude-code", pid: LeaseManager.noOwnerPid, name: "fixing tests", ownerVerified: true, now: t0)
        XCTAssertEqual(second, .queued(position: 1, reason: .busy(holder: "claude-code")),
                       "a second anonymous session must wait its turn")
        // Stated as a failure rather than as an assertion inside the branch:
        // the line above has already established `second` is `.queued`, so a
        // `.granted` body could only ever run when the test was failing anyway
        // — which made the check that pins the actual field-observed bug
        // unreachable in every passing run.
        if case .granted(let id) = second {
            XCTFail("a second anonymous session was handed lease \(id)")
        }
        XCTAssertEqual(m.holder?.id, first, "the original session still owns the microphone")
    }

    // Named sessions of the same tool are told apart, so they queue rather than
    // collide — and the one that named itself still gets its own lease back.
    func testNamedSessionsOfTheSameHarnessAreDistinct() {
        let m = manager()
        guard case .granted(let first) = m.claim(harness: "claude-code", pid: 1, name: "fixing tests", ownerVerified: true, now: t0) else {
            return XCTFail("expected grant")
        }
        XCTAssertEqual(m.claim(harness: "claude-code", pid: 2, name: "fixing tests", ownerVerified: true, now: t0),
                       .queued(position: 1, reason: .busy(holder: "claude-code")))
        guard case .granted(let again) = m.claim(harness: "claude-code", pid: 1, name: "fixing tests", ownerVerified: true, now: t0) else {
            return XCTFail("the named holder re-claiming should get its own lease back")
        }
        XCTAssertEqual(first, again)
    }

    // The harness id and the owner pid both arrive over the socket, so on their
    // own they are a claim rather than evidence. Anybody can read a running
    // agent's pid out of `ps`; echoing it back with that agent's harness id
    // used to be enough to be handed the live lease — and a lease carries the
    // user's consent, so a process holding no microphone permission of its own
    // inherited one that did.
    func testAnUnverifiedOwnerIsNeverHandedTheHoldersLease() {
        let m = manager()
        guard case .granted(let first) = m.claim(harness: "claude-code", pid: 42,
                                                 name: "fixing tests", ownerVerified: true,
                                                 now: t0) else {
            return XCTFail("expected grant")
        }
        let impostor = m.claim(harness: "claude-code", pid: 42, name: "reading mail",
                               ownerVerified: false, now: t0)
        XCTAssertEqual(impostor, .queued(position: 1, reason: .busy(holder: "claude-code")),
                       "a caller that cannot prove the pid it names must queue like anyone else")
        if case .granted(let id) = impostor {
            XCTFail("an unverified claimant was handed lease \(id)")
        }
        XCTAssertEqual(m.holder?.id, first, "the real session still owns the microphone")
        XCTAssertEqual(m.holder?.name, "fixing tests",
                       "and the impostor may not rename what the user is reading")
    }

    // The same hijack, arriving by the queue instead of by the holder.
    //
    // A waiting agent is the leader; the microphone comes free; a local process
    // echoes back that agent's harness and the pid it read out of `ps`. If the
    // leader check cannot tell a verified claimant from an unverified one, the
    // impostor is taken for the leader and handed the lease the moment it is
    // available — and under the shipped default there is no prompt in the way.
    func testAnUnverifiedClaimantCannotTakeAVerifiedWaitersPlaceInTheQueue() {
        let m = manager()
        guard case .granted(let held) = m.claim(harness: "codex", pid: 3,
                                                name: "writing docs", ownerVerified: true,
                                                now: t0) else {
            return XCTFail("expected the first claim to be granted")
        }
        // The real agent queues behind it.
        XCTAssertEqual(m.claim(harness: "claude-code", pid: 42, name: "fixing tests",
                               ownerVerified: true, now: t0),
                       .queued(position: 1, reason: .busy(holder: "codex")))

        // The microphone comes free.
        m.release(lease: held, now: t0)
        let free = t0.addingTimeInterval(LeaseConfig.default.cooldown + 1)

        // The impostor arrives naming the waiting agent's own harness and pid.
        let impostor = m.claim(harness: "claude-code", pid: 42, name: "reading mail",
                               ownerVerified: false, now: free)
        if case .granted(let id) = impostor {
            XCTFail("an unverified claimant was handed lease \(id) from the queue")
        }
        XCTAssertNil(m.holder, "and the microphone stays free for the agent whose turn it is")

        // The real one comes back for its turn and still has it.
        guard case .granted = m.claim(harness: "claude-code", pid: 42, name: "fixing tests",
                                      ownerVerified: true, now: free) else {
            return XCTFail("the verified waiter lost the place it was holding")
        }
    }

    func testHolderKeepsTheLeaseAcrossManyCalls() {
        let m = manager()
        guard case .granted(let id) = m.claim(harness: "claude-code", pid: 1, name: "fixing tests", ownerVerified: true, now: t0) else {
            return XCTFail("expected grant")
        }
        // A whole conversation: speak, listen, speak, listen…
        for step in 1...10 {
            let now = t0.addingTimeInterval(Double(step) * 10)
            XCTAssertNoThrow(try m.validate(lease: id, now: now).get(),
                             "the holder must not lose the lease mid-conversation")
        }
    }

    func testNonHolderIsRefused() {
        let m = manager()
        _ = m.claim(harness: "claude-code", pid: 1, name: "fixing tests", ownerVerified: true, now: t0)
        XCTAssertEqual(m.validate(lease: "not-a-lease", now: t0), .failure(.notHolder))
    }

    // MARK: release, cooldown, hand-off

    func testReleaseHandsOffToTheQueueOnlyAfterCooldown() {
        var config = LeaseConfig.default
        config.cooldown = 2
        let m = manager(config)

        guard case .granted(let id) = m.claim(harness: "claude-code", pid: 1, name: "fixing tests", ownerVerified: true, now: t0) else {
            return XCTFail("expected grant")
        }
        _ = m.claim(harness: "codex", pid: 2, name: "fixing tests", ownerVerified: true, now: t0)
        m.release(lease: id, now: t0)

        // Still cooling: the waiting agent is told why, not just "busy".
        XCTAssertEqual(m.claim(harness: "codex", pid: 2, name: "fixing tests", ownerVerified: true, now: t0.addingTimeInterval(1)),
                       .queued(position: 1, reason: .cooldown))

        guard case .granted = m.claim(harness: "codex", pid: 2, name: "fixing tests", ownerVerified: true, now: t0.addingTimeInterval(2.1)) else {
            return XCTFail("codex should take over once the cooldown has passed")
        }
        XCTAssertEqual(m.holder?.harness, "codex")
        XCTAssertTrue(m.queue.isEmpty, "the new holder must be removed from the queue")
    }

    func testReleasingSomeoneElsesLeaseDoesNothing() {
        let m = manager()
        _ = m.claim(harness: "claude-code", pid: 1, name: "fixing tests", ownerVerified: true, now: t0)
        m.release(lease: "someone-elses-id", now: t0)
        XCTAssertEqual(m.holder?.harness, "claude-code")
    }

    // MARK: the leak — a lease nobody releases

    // `release` is precisely the call a crashed agent never makes, so this is
    // the common failure, not an exotic one.
    func testIdleLeaseIsReapedSoOthersAreNotBlockedForever() {
        var config = LeaseConfig.default
        config.leaseTTL = 30
        config.cooldown = 0
        let m = manager(config)

        guard case .granted(let id) = m.claim(harness: "claude-code", pid: 1, name: "fixing tests", ownerVerified: true, now: t0) else {
            return XCTFail("expected grant")
        }
        let later = t0.addingTimeInterval(31)
        XCTAssertEqual(m.validate(lease: id, now: later), .failure(.notHolder))
        guard case .granted = m.claim(harness: "codex", pid: 2, name: "fixing tests", ownerVerified: true, now: later) else {
            return XCTFail("an abandoned lease must not lock the microphone forever")
        }
    }

    // Using the lease is the heartbeat: an agent mid-conversation must never be
    // reaped just because the conversation is long.
    func testUseRefreshesTheLease() {
        var config = LeaseConfig.default
        config.leaseTTL = 30
        let m = manager(config)
        guard case .granted(let id) = m.claim(harness: "claude-code", pid: 1, name: "fixing tests", ownerVerified: true, now: t0) else {
            return XCTFail("expected grant")
        }
        for step in 1...10 {
            let now = t0.addingTimeInterval(Double(step) * 20)   // always inside the TTL
            XCTAssertNoThrow(try m.validate(lease: id, now: now).get())
        }
        XCTAssertEqual(m.holder?.harness, "claude-code")
    }

    func testDeadHolderIsReapedImmediatelyWithoutWaitingOutTheTTL() {
        var config = LeaseConfig.default
        config.leaseTTL = 600
        config.cooldown = 0
        let m = manager(config, alive: [7])
        _ = m.claim(harness: "claude-code", pid: 42, name: "fixing tests", ownerVerified: true, now: t0)

        m.reap(now: t0.addingTimeInterval(1))   // 42 is not in `alive`
        XCTAssertNil(m.holder, "a lease whose harness process died must not survive its TTL")
    }

    func testQueuedEntriesExpireSoStalePromptsNeverFire() {
        var config = LeaseConfig.default
        config.queueTTL = 60
        let m = manager(config)
        _ = m.claim(harness: "claude-code", pid: 1, name: "fixing tests", ownerVerified: true, now: t0)
        _ = m.claim(harness: "codex", pid: 2, name: "fixing tests", ownerVerified: true, now: t0)
        XCTAssertEqual(m.queue.count, 1)

        m.reap(now: t0.addingTimeInterval(61))
        XCTAssertTrue(m.queue.isEmpty, "a caller that stopped waiting must not be handed the mic later")
    }

    func testDeadQueuedEntriesAreDropped() {
        // The queued harness dies while waiting — it must not be handed the
        // microphone when its turn eventually comes around.
        final class Liveness { var alive: Set<pid_t> = [1, 2] }
        let liveness = Liveness()
        let m = LeaseManager(isAlive: { liveness.alive.contains($0) })

        _ = m.claim(harness: "claude-code", pid: 1, name: "fixing tests", ownerVerified: true, now: t0)
        _ = m.claim(harness: "codex", pid: 2, name: "fixing tests", ownerVerified: true, now: t0)
        XCTAssertEqual(m.queue.count, 1)

        liveness.alive.remove(2)
        m.reap(now: t0.addingTimeInterval(1))
        XCTAssertTrue(m.queue.isEmpty)
    }

    // MARK: user override and the master switch

    func testForceReleaseTakesTheMicrophoneBack() {
        let m = manager()
        guard case .granted(let id) = m.claim(harness: "claude-code", pid: 1, name: "fixing tests", ownerVerified: true, now: t0) else {
            return XCTFail("expected grant")
        }
        m.forceRelease(now: t0)
        XCTAssertNil(m.holder)
        XCTAssertEqual(m.validate(lease: id, now: t0), .failure(.notHolder))
    }

    func testDisabledRefusesEverythingAndClearsTheQueue() {
        let m = manager()
        guard case .granted(let id) = m.claim(harness: "claude-code", pid: 1, name: "fixing tests", ownerVerified: true, now: t0) else {
            return XCTFail("expected grant")
        }
        _ = m.claim(harness: "codex", pid: 2, name: "fixing tests", ownerVerified: true, now: t0)

        m.disable()
        XCTAssertNil(m.holder)
        XCTAssertTrue(m.queue.isEmpty)
        // `disabled` is distinct from `denied` on purpose: it means stop asking,
        // not try again in a moment.
        XCTAssertEqual(m.claim(harness: "claude-code", pid: 1, name: "fixing tests", ownerVerified: true, now: t0), .disabled)
        XCTAssertEqual(m.validate(lease: id, now: t0), .failure(.disabled))
    }

    // MARK: ordering

    func testQueueIsFirstComeFirstServed() {
        var config = LeaseConfig.default
        config.cooldown = 0
        let m = manager(config)
        guard case .granted(let id) = m.claim(harness: "claude-code", pid: 1, name: "fixing tests", ownerVerified: true, now: t0) else {
            return XCTFail("expected grant")
        }
        _ = m.claim(harness: "codex", pid: 2, name: "fixing tests", ownerVerified: true, now: t0.addingTimeInterval(1))
        _ = m.claim(harness: "cursor", pid: 3, name: "fixing tests", ownerVerified: true, now: t0.addingTimeInterval(2))
        XCTAssertEqual(m.claim(harness: "cursor", pid: 3, name: "fixing tests", ownerVerified: true, now: t0.addingTimeInterval(3)),
                       .queued(position: 2, reason: .busy(holder: "claude-code")))

        m.release(lease: id, now: t0.addingTimeInterval(4))
        let now = t0.addingTimeInterval(5)

        // Cursor asks first, but codex has waited longer — granting to whoever
        // asks would starve it.
        XCTAssertEqual(m.claim(harness: "cursor", pid: 3, name: "fixing tests", ownerVerified: true, now: now),
                       .queued(position: 2, reason: .busy(holder: "codex")))
        XCTAssertNil(m.holder, "the lease stays idle until its rightful owner comes back for it")

        // No auto-promotion on release: a lease handed to an agent that isn't
        // asking would start its TTL ticking against a caller who cannot even
        // be told the lease id — the only way to learn it is to claim.
        guard case .granted = m.claim(harness: "codex", pid: 2, name: "fixing tests", ownerVerified: true, now: now) else {
            return XCTFail("the longest waiter takes over when it comes back")
        }
        XCTAssertEqual(m.holder?.harness, "codex")
        XCTAssertEqual(m.claim(harness: "cursor", pid: 3, name: "fixing tests", ownerVerified: true, now: now),
                       .queued(position: 1, reason: .busy(holder: "codex")))
    }
}
