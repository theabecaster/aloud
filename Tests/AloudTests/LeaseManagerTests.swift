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
    private func manager(_ config: LeaseConfig = .default,
                         alive: Set<pid_t> = [1, 2, 3, 42]) -> LeaseManager {
        LeaseManager(config: config, isAlive: { alive.contains($0) })
    }

    // MARK: granting and holding

    func testFirstClaimIsGranted() {
        let m = manager()
        guard case .granted(let id) = m.claim(harness: "claude-code", pid: 1, now: t0) else {
            return XCTFail("first claim should be granted")
        }
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(m.holder?.harness, "claude-code")
    }

    func testSecondHarnessQueuesBehindTheHolder() {
        let m = manager()
        _ = m.claim(harness: "claude-code", pid: 1, now: t0)
        let result = m.claim(harness: "codex", pid: 2, now: t0)
        XCTAssertEqual(result, .queued(position: 1, reason: .busy(holder: "claude-code")))
    }

    // Agents re-claim to find out whether their turn has come. That must not
    // hand them a second lease, nor a second place in the queue.
    func testReclaimingIsIdempotentForHolderAndQueue() {
        let m = manager()
        guard case .granted(let first) = m.claim(harness: "claude-code", pid: 1, now: t0) else {
            return XCTFail("expected grant")
        }
        guard case .granted(let again) = m.claim(harness: "claude-code", pid: 1, now: t0) else {
            return XCTFail("holder re-claiming should get its own lease back")
        }
        XCTAssertEqual(first, again)

        _ = m.claim(harness: "codex", pid: 2, now: t0)
        _ = m.claim(harness: "codex", pid: 2, now: t0)
        _ = m.claim(harness: "codex", pid: 2, now: t0)
        XCTAssertEqual(m.queue.count, 1, "re-claiming must not stack duplicate queue entries")
    }

    func testHolderKeepsTheLeaseAcrossManyCalls() {
        let m = manager()
        guard case .granted(let id) = m.claim(harness: "claude-code", pid: 1, now: t0) else {
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
        _ = m.claim(harness: "claude-code", pid: 1, now: t0)
        XCTAssertEqual(m.validate(lease: "not-a-lease", now: t0), .failure(.notHolder))
    }

    // MARK: release, cooldown, hand-off

    func testReleaseHandsOffToTheQueueOnlyAfterCooldown() {
        var config = LeaseConfig.default
        config.cooldown = 2
        let m = manager(config)

        guard case .granted(let id) = m.claim(harness: "claude-code", pid: 1, now: t0) else {
            return XCTFail("expected grant")
        }
        _ = m.claim(harness: "codex", pid: 2, now: t0)
        m.release(lease: id, now: t0)

        // Still cooling: the waiting agent is told why, not just "busy".
        XCTAssertEqual(m.claim(harness: "codex", pid: 2, now: t0.addingTimeInterval(1)),
                       .queued(position: 1, reason: .cooldown))

        guard case .granted = m.claim(harness: "codex", pid: 2, now: t0.addingTimeInterval(2.1)) else {
            return XCTFail("codex should take over once the cooldown has passed")
        }
        XCTAssertEqual(m.holder?.harness, "codex")
        XCTAssertTrue(m.queue.isEmpty, "the new holder must be removed from the queue")
    }

    func testReleasingSomeoneElsesLeaseDoesNothing() {
        let m = manager()
        _ = m.claim(harness: "claude-code", pid: 1, now: t0)
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

        guard case .granted(let id) = m.claim(harness: "claude-code", pid: 1, now: t0) else {
            return XCTFail("expected grant")
        }
        let later = t0.addingTimeInterval(31)
        XCTAssertEqual(m.validate(lease: id, now: later), .failure(.notHolder))
        guard case .granted = m.claim(harness: "codex", pid: 2, now: later) else {
            return XCTFail("an abandoned lease must not lock the microphone forever")
        }
    }

    // Using the lease is the heartbeat: an agent mid-conversation must never be
    // reaped just because the conversation is long.
    func testUseRefreshesTheLease() {
        var config = LeaseConfig.default
        config.leaseTTL = 30
        let m = manager(config)
        guard case .granted(let id) = m.claim(harness: "claude-code", pid: 1, now: t0) else {
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
        _ = m.claim(harness: "claude-code", pid: 42, now: t0)

        m.reap(now: t0.addingTimeInterval(1))   // 42 is not in `alive`
        XCTAssertNil(m.holder, "a lease whose harness process died must not survive its TTL")
    }

    func testQueuedEntriesExpireSoStalePromptsNeverFire() {
        var config = LeaseConfig.default
        config.queueTTL = 60
        let m = manager(config)
        _ = m.claim(harness: "claude-code", pid: 1, now: t0)
        _ = m.claim(harness: "codex", pid: 2, now: t0)
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

        _ = m.claim(harness: "claude-code", pid: 1, now: t0)
        _ = m.claim(harness: "codex", pid: 2, now: t0)
        XCTAssertEqual(m.queue.count, 1)

        liveness.alive.remove(2)
        m.reap(now: t0.addingTimeInterval(1))
        XCTAssertTrue(m.queue.isEmpty)
    }

    // MARK: user override and the master switch

    func testForceReleaseTakesTheMicrophoneBack() {
        let m = manager()
        guard case .granted(let id) = m.claim(harness: "claude-code", pid: 1, now: t0) else {
            return XCTFail("expected grant")
        }
        m.forceRelease(now: t0)
        XCTAssertNil(m.holder)
        XCTAssertEqual(m.validate(lease: id, now: t0), .failure(.notHolder))
    }

    func testDisabledRefusesEverythingAndClearsTheQueue() {
        let m = manager()
        guard case .granted(let id) = m.claim(harness: "claude-code", pid: 1, now: t0) else {
            return XCTFail("expected grant")
        }
        _ = m.claim(harness: "codex", pid: 2, now: t0)

        m.disable()
        XCTAssertNil(m.holder)
        XCTAssertTrue(m.queue.isEmpty)
        // `disabled` is distinct from `denied` on purpose: it means stop asking,
        // not try again in a moment.
        XCTAssertEqual(m.claim(harness: "claude-code", pid: 1, now: t0), .disabled)
        XCTAssertEqual(m.validate(lease: id, now: t0), .failure(.disabled))
    }

    // MARK: ordering

    func testQueueIsFirstComeFirstServed() {
        var config = LeaseConfig.default
        config.cooldown = 0
        let m = manager(config)
        guard case .granted(let id) = m.claim(harness: "claude-code", pid: 1, now: t0) else {
            return XCTFail("expected grant")
        }
        _ = m.claim(harness: "codex", pid: 2, now: t0.addingTimeInterval(1))
        _ = m.claim(harness: "cursor", pid: 3, now: t0.addingTimeInterval(2))
        XCTAssertEqual(m.claim(harness: "cursor", pid: 3, now: t0.addingTimeInterval(3)),
                       .queued(position: 2, reason: .busy(holder: "claude-code")))

        m.release(lease: id, now: t0.addingTimeInterval(4))
        let now = t0.addingTimeInterval(5)

        // Cursor asks first, but codex has waited longer — granting to whoever
        // asks would starve it.
        XCTAssertEqual(m.claim(harness: "cursor", pid: 3, now: now),
                       .queued(position: 2, reason: .busy(holder: "codex")))
        XCTAssertNil(m.holder, "the lease stays idle until its rightful owner comes back for it")

        // No auto-promotion on release: a lease handed to an agent that isn't
        // asking would start its TTL ticking against a caller who cannot even
        // be told the lease id — the only way to learn it is to claim.
        guard case .granted = m.claim(harness: "codex", pid: 2, now: now) else {
            return XCTFail("the longest waiter takes over when it comes back")
        }
        XCTAssertEqual(m.holder?.harness, "codex")
        XCTAssertEqual(m.claim(harness: "cursor", pid: 3, now: now),
                       .queued(position: 1, reason: .busy(holder: "codex")))
    }
}
