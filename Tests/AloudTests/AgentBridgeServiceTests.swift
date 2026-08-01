import XCTest
@testable import Aloud

// The service is where the gate, the lease and consent meet. Its refusals are
// the feature's public contract — an installed skill teaches agents to react to
// `disabled` differently from `denied` differently from `queued`, so a wrong
// reason here makes an agent do the wrong thing in a way no crash reveals.
@MainActor
final class AgentBridgeServiceTests: XCTestCase {

    // A stand-in for DictationController: records what it was asked to do and
    // answers instantly, so nothing here needs audio, a model, or a GUI.
    private final class FakeHost: AgentVoiceHost, @unchecked Sendable {
        var spoken: [String] = []
        var prompts: [ConsentPrompt] = []
        var dismissals = 0
        var listenCount = 0
        var listenFrom: Date?
        var transcript = AgentTranscript(text: "roll it back", raw: "uh roll it back",
                                         cleanup: .concise)
        var speakError: Error?
        var listenError: Error?
        // Drives the service's "don't prompt over a live dictation" guard.
        var userDictationInProgress = false

        // Ordered log of everything the host was asked to do, so a test can
        // assert the microphone opens AFTER the prompt has been spoken.
        var events: [String] = []
        // Fires while `speak` is still "playing", so a test can answer the
        // prompt the way a user who doesn't wait for the sentence to end does.
        // Main-actor typed on purpose: the pill's callbacks belong to the
        // service, which is @MainActor, and `speak` is not — calling them
        // straight from here trips the executor assumption and traps.
        var duringSpeak: (@MainActor @Sendable () -> Void)?
        func speak(_ text: String) async throws {
            if let speakError { throw speakError }
            spoken.append(text)
            events.append("speak")
            await duringSpeak?()
        }
        func beginConsentCapture() async {
            listenedForConsent = true
            events.append("mic")
        }
        // The pill's accept/deny are captured so a test can answer the way a
        // user clicking the indicator would, not just via the service API.
        var acceptFromPill: (() -> Void)?
        var declineFromPill: (() -> Void)?
        // `heardFromMic` is the seam that was missing in the app: the host
        // opens the microphone during a confirm-by-voice prompt and reports
        // what it hears. A fake that did not expose it let the whole mode look
        // tested while nothing ever fed the policy a word.
        var heardFromMic: ((String) -> Void)?
        var listenedForConsent = false
        var dismissedAccepted: [Bool] = []
        func presentConsent(_ prompt: ConsentPrompt,
                            onAccept: @escaping () -> Void,
                            onDecline: @escaping () -> Void,
                            onHeard: @escaping (String) -> Void) async {
            prompts.append(prompt)
            acceptFromPill = onAccept
            declineFromPill = onDecline
            heardFromMic = onHeard
            events.append("prompt")
        }
        func dismissConsent(accepted: Bool) async {
            dismissals += 1
            dismissedAccepted.append(accepted)
        }
        var sessionsEnded = 0
        func endAgentSession() async {
            sessionsEnded += 1
            events.append("end")
        }
        func listen(from: Date) async throws -> AgentTranscript {
            listenCount += 1
            listenFrom = from
            if let listenError { throw listenError }
            return transcript
        }

        // Streaming variant. `polled` records what the agent asked for so a
        // test can assert the ceiling was passed through rather than ignored.
        var sessions: [String] = []
        var polled: [TimeInterval] = []
        var stopped: [String] = []
        var partial = "roll it"
        func startListenSession() async throws -> String {
            let id = "S\(sessions.count + 1)"
            sessions.append(id)
            return id
        }
        func pollListenSession(id: String, waitingUpTo seconds: TimeInterval) async throws
            -> (text: String, speaking: Bool, silentFor: TimeInterval?) {
            guard sessions.contains(id) else { throw AgentListenError.busy }
            polled.append(seconds)
            return (partial, true, 0.2)
        }
        func stopListenSession(id: String) async throws -> AgentTranscript {
            guard sessions.contains(id) else { throw AgentListenError.busy }
            stopped.append(id)
            return transcript
        }
    }

    // One fixed suite for the whole class, wiped before each test rather than a
    // fresh UUID per run. cfprefsd rewrites the plist asynchronously after
    // tearDown, so a random name loses that race and leaves a file behind every
    // single time — hundreds had accumulated in ~/Library/Preferences. A stable
    // name still isolates (the domain is emptied on the way in) and can leave
    // at most one file.
    private static let suiteName = "aloud-bridge-service"
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var host: FakeHost!
    // A clock the test drives, so the lease cooldown and the refusal back-off
    // can be stepped over instead of waited out.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000_000)
        var current: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }; value = value.addingTimeInterval(seconds)
        }
    }
    private var clock: Clock!

    override func setUp() {
        super.setUp()
        suiteName = Self.suiteName
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        host = FakeHost()
        clock = Clock()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        // removePersistentDomain empties the domain but leaves the plist on
        // disk, so a per-run suite name drops a file in ~/Library/Preferences
        // every single time. Hundreds had piled up before anyone noticed.
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: plist)
        super.tearDown()
    }

    private func makeService(mode: AgentConsentMode = .open,
                             enabled: Bool = true,
                             harnesses: [String] = ["claude-code"]) -> AgentBridgeService {
        let settings = SettingsStore(defaults: defaults)
        settings.experimentalAgentVoice = enabled
        settings.installedHarnesses = harnesses
        settings.agentConsentMode = mode
        let clock = self.clock!
        return AgentBridgeService(leases: LeaseManager(isAlive: { _ in true }),
                                  consent: ConsentPolicy(mode: mode),
                                  settings: settings,
                                  host: host,
                                  now: { clock.current })
    }

    private func request(_ op: BridgeOperation, lease: String? = nil,
                         text: String? = nil, name: String = "fixing tests") -> BridgeRequest {
        var request = BridgeRequest(op: op, harness: "claude-code", pid: 4242,
                                    lease: lease, text: text)
        request.name = name
        return request
    }

    private var peer: BridgeServer.PeerIdentity {
        BridgeServer.PeerIdentity(pid: 4242, name: "claude")
    }

    // MARK: review-hardening regressions

    // A release naming a lease that no longer holds the microphone must not
    // tear down whoever holds it now — another agent, or the user's own
    // dictation. Before the fix, `release` called endAgentSession
    // unconditionally.
    func testStaleReleaseDoesNotEndTheLiveSession() async {
        let service = makeService(mode: .open)
        _ = await service.handle(request(.claim), peer: peer)
        let before = host.sessionsEnded
        _ = await service.handle(request(.release, lease: "not-the-holder"), peer: peer)
        XCTAssertEqual(host.sessionsEnded, before,
                       "a release for a non-holding lease must not end the live session")
    }

    // A holder re-claiming while its consent prompt is still open must not
    // start a second prompt — that overwrote the first continuation and hung
    // the original caller forever.
    func testReclaimWhileConsentPendingDoesNotStartASecondPrompt() async {
        let service = makeService(mode: .confirmByVoice)
        let caller = peer
        let claimReq = request(.claim)
        async let first = service.handle(claimReq, peer: caller)
        try? await Task.sleep(nanoseconds: 80_000_000)   // let the prompt come up
        let second = await service.handle(request(.claim), peer: caller)
        XCTAssertFalse(second.ok)
        XCTAssertEqual(second.reason, .queued,
                       "a re-claim during an open prompt is told to wait, not given a second prompt")
        XCTAssertEqual(host.prompts.count, 1, "exactly one prompt, not two")
        // Let the original resolve so the task doesn't leak.
        host.acceptFromPill?()
        _ = await first
    }

    // A claim that would prompt while the user is mid-dictation is refused
    // rather than seizing the hotkey out from under them.
    func testClaimIsRefusedWhileTheUserIsDictating() async {
        let service = makeService(mode: .confirmByVoice)
        host.userDictationInProgress = true
        let response = await service.handle(request(.claim), peer: peer)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.reason, .queued)
        XCTAssertEqual(host.prompts.count, 0, "no consent prompt over a live dictation")
    }

    // MARK: the gate

    func testEverythingIsRefusedWhileTheExperimentIsOff() async {
        let service = makeService(enabled: false)
        for op in [BridgeOperation.claim, .speak, .listen, .release] {
            let response = await service.handle(request(op, lease: "L1", text: "hi"), peer: peer)
            XCTAssertFalse(response.ok, "\(op) must not work with the gate off")
            XCTAssertEqual(response.reason, .disabled,
                           "`disabled` tells the agent to stop asking; any other reason invites a retry")
        }
        XCTAssertTrue(host.spoken.isEmpty)
        XCTAssertEqual(host.listenCount, 0)
    }

    // An agent has to be able to discover that voice is off without that
    // discovery itself being refused as unreachable.
    func testStatusStillAnswersWhileTheExperimentIsOff() async {
        let service = makeService(enabled: false)
        let response = await service.handle(request(.status), peer: peer)
        XCTAssertEqual(response.reason, .disabled)
        XCTAssertEqual(response.enabled, false)
    }

    func testStatusNeverOpensTheMicrophone() async {
        let service = makeService()
        _ = await service.handle(request(.status), peer: peer)
        XCTAssertEqual(host.listenCount, 0)
        XCTAssertTrue(host.prompts.isEmpty)
    }

    // MARK: claim and consent

    func testOpenModeGrantsWithoutAsking() async {
        let service = makeService(mode: .open)
        let response = await service.handle(request(.claim), peer: peer)
        XCTAssertTrue(response.ok)
        XCTAssertNotNil(response.lease)
        XCTAssertTrue(host.prompts.isEmpty, "open mode asks nothing")
    }

    func testConfirmByVoiceSpeaksThePromptAndWaitsForAnAnswer() async {
        let service = makeService(mode: .confirmByVoice)
        let claim = Task { await service.handle(self.request(.claim), peer: self.peer) }

        // Let the claim reach the prompt, then answer as the user would.
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(host.prompts.count, 1)
        XCTAssertEqual(host.spoken.count, 1, "the prompt is spoken, not just drawn")
        let lease = try? XCTUnwrap(host.prompts.first?.lease)
        service.heardConsent("accept", lease: lease ?? "")

        let response = await claim.value
        XCTAssertTrue(response.ok)
        XCTAssertEqual(host.dismissals, 1, "the prompt comes down once answered")
    }

    // The bug a real run found: confirm-by-voice is the DEFAULT mode, and
    // nothing opened the microphone or fed the policy a word. The consent
    // policy classified utterances perfectly in 24 tests and was never handed
    // one, so saying "accept" did nothing and the prompt could only time out.
    func testSpeakingAcceptIsActuallyHeard() async {
        let service = makeService(mode: .confirmByVoice)
        let claim = Task { await service.handle(self.request(.claim), peer: self.peer) }
        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertTrue(host.listenedForConsent,
                      "confirm-by-voice has to open the microphone — it is the only way to answer")
        let heard = try? XCTUnwrap(host.heardFromMic)
        heard?("accept")

        let response = await claim.value
        XCTAssertTrue(response.ok, "a spoken accept must grant the lease")
    }

    // The bug a real run found, after the mic was finally opened at all:
    // opening it BEFORE speaking meant Aloud transcribed its own prompt and the
    // user's reply arrived glued to the end of it — "…say accept or decline.
    // Accept." — which the matcher correctly refused as not-an-answer. So
    // speaking never worked, and the log showed the recogniser doing its job on
    // poisoned input. speak() returns when playback ends; ordering is the gate.
    func testTheMicrophoneOpensOnlyAfterThePromptHasBeenSpoken() async {
        let service = makeService(mode: .confirmByVoice)
        let claim = Task { await service.handle(self.request(.claim), peer: self.peer) }
        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(host.events, ["prompt", "speak", "mic"],
                       "the microphone must not be open while Aloud is talking into it")
        host.heardFromMic?("accept")
        _ = await claim.value
    }

    // The other half of what a real run showed: a prompt that is refused or
    // expires left the pill on screen with nothing behind it.
    func testARefusedPromptTakesTheIndicatorDownAgain() async {
        let service = makeService(mode: .confirmByVoice)
        let claim = Task { await service.handle(self.request(.claim), peer: self.peer) }
        try? await Task.sleep(nanoseconds: 60_000_000)
        host.heardFromMic?("decline")
        _ = await claim.value

        XCTAssertEqual(host.dismissedAccepted, [false],
                       "the host has to be told the session is not proceeding, or the pill stays up")
    }

    func testDecliningRefusesWithDeniedAndFreesTheLease() async {
        let service = makeService(mode: .confirmOnScreen)
        let claim = Task { await service.handle(self.request(.claim), peer: self.peer) }
        try? await Task.sleep(nanoseconds: 60_000_000)
        let lease = host.prompts.first?.lease ?? ""
        service.declineConsent(lease: lease)

        let response = await claim.value
        XCTAssertFalse(response.ok)
        // `denied` is about this request only — asking again later is fine.
        // Reporting `disabled` here would make the agent give up for good.
        XCTAssertEqual(response.reason, .denied)
        XCTAssertTrue(host.spoken.isEmpty, "on-screen mode never speaks")
    }

    // The installed instructions tell agents that `denied` means this request
    // only and not to retry-loop — but instructions are not enforcement. An
    // agent that ignores them could re-prompt a user who just said no, over and
    // over, which is how a feature gets switched off for good. Saying no has to
    // actually buy quiet.
    func testAHarnessThatWasRefusedCannotImmediatelyAskAgain() async {
        let service = makeService(mode: .confirmOnScreen)
        let claim = Task { await service.handle(self.request(.claim), peer: self.peer) }
        try? await Task.sleep(nanoseconds: 60_000_000)
        service.declineConsent(lease: host.prompts.first?.lease ?? "")
        _ = await claim.value

        let again = await service.handle(request(.claim), peer: peer)
        XCTAssertEqual(again.reason, .denied)
        XCTAssertNotNil(again.retryAfter, "an agent has to be told how long to stay quiet for")
        XCTAssertEqual(host.prompts.count, 1, "the user must not be asked a second time")
    }

    // The back-off is per harness: one agent being told no says nothing about
    // whether the user wants to hear from a different one.
    func testARefusalDoesNotSilenceOtherHarnesses() async {
        let service = makeService(mode: .confirmOnScreen)
        let claim = Task { await service.handle(self.request(.claim), peer: self.peer) }
        try? await Task.sleep(nanoseconds: 60_000_000)
        service.declineConsent(lease: host.prompts.first?.lease ?? "")
        _ = await claim.value

        // Past the audio cooldown the declined session started.
        clock.advance(5)

        var other = request(.claim)
        other.harness = "codex"
        other.pid = 5150
        let second = Task {
            await service.handle(other, peer: BridgeServer.PeerIdentity(pid: 5150, name: "codex"))
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(host.prompts.count, 2, "a different harness still gets to ask")
        service.declineConsent(lease: host.prompts.last?.lease ?? "")
        _ = await second.value
    }

    // MARK: leases

    func testASecondHarnessIsQueuedAndToldWhoHasIt() async {
        let service = makeService(mode: .open)
        _ = await service.handle(request(.claim), peer: peer)

        var other = request(.claim)
        other.harness = "codex"
        other.pid = 5150
        let response = await service.handle(other,
                                            peer: BridgeServer.PeerIdentity(pid: 5150, name: "codex"))
        XCTAssertEqual(response.reason, .queued)
        XCTAssertEqual(response.position, 1)
        XCTAssertEqual(response.queuedBehind, "claude-code",
                       "an agent that can name the holder can say something useful instead of spinning")
        XCTAssertNotNil(response.retryAfter)
    }

    // An agent cannot be pushed to between CLI calls — the connection closes
    // after every one — but it can hold one open. `claim --wait` is what lets a
    // second agent park in a background shell and be woken when the microphone
    // is free, instead of spending a model turn on every look.
    func testClaimWithWaitParksUntilTheHolderReleases() async {
        let service = makeService(mode: .open)
        let first = await service.handle(request(.claim), peer: peer)
        let held = try? XCTUnwrap(first.lease)

        var waiting = request(.claim)
        waiting.harness = "codex"
        waiting.pid = 5150
        waiting.wait = 30
        let parked = Task {
            await service.handle(waiting, peer: BridgeServer.PeerIdentity(pid: 5150, name: "codex"))
        }

        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(parked.isCancelled)
        XCTAssertEqual(service.holderHarnessForTesting, "claude-code",
                       "the waiter must not have taken it while someone still held it")

        _ = await service.handle(request(.release, lease: held), peer: peer)
        clock.advance(5)                       // past the audio cooldown

        let granted = await parked.value
        XCTAssertTrue(granted.ok, "the parked agent is woken with the lease, not a refusal")
        XCTAssertNotNil(granted.lease)
    }

    // A wait that outlives the shell holding it would reserve the microphone
    // for a caller that has already gone, so it has a ceiling and reports the
    // queue honestly when it expires.
    func testAWaitThatExpiresStillReportsTheQueue() async {
        let service = makeService(mode: .open)
        _ = await service.handle(request(.claim), peer: peer)

        var waiting = request(.claim)
        waiting.harness = "codex"
        waiting.pid = 5150
        waiting.wait = 0.4
        let response = await service.handle(waiting,
                                            peer: BridgeServer.PeerIdentity(pid: 5150, name: "codex"))
        XCTAssertEqual(response.reason, .queued)
        XCTAssertEqual(response.queuedBehind, "claude-code")
    }

    func testSpeakAndListenNeedTheLease() async {
        let service = makeService(mode: .open)
        for op in [BridgeOperation.speak, .listen] {
            let response = await service.handle(request(op, lease: "not-a-lease", text: "hi"),
                                                peer: peer)
            XCTAssertEqual(response.reason, .notHolder,
                           "`notHolder` means the session is over — there is nothing to wait for")
        }
        XCTAssertEqual(host.listenCount, 0)
        XCTAssertTrue(host.spoken.isEmpty)
    }

    func testSpeakAndListenWithoutALeaseAreARequestError() async {
        let service = makeService(mode: .open)
        let speak = await service.handle(request(.speak, text: "hi"), peer: peer)
        XCTAssertEqual(speak.reason, .badRequest)
        let listen = await service.handle(request(.listen), peer: peer)
        XCTAssertEqual(listen.reason, .badRequest)
    }

    // The whole point of the lease: one conversation, many turns.
    func testAWholeConversationRunsOnOneClaim() async {
        let service = makeService(mode: .open)
        let claimed = await service.handle(request(.claim), peer: peer)
        let lease = try? XCTUnwrap(claimed.lease)

        for _ in 0..<3 {
            let asked = await service.handle(request(.speak, lease: lease, text: "which one?"),
                                             peer: peer)
            XCTAssertTrue(asked.ok)
            let heard = await service.handle(request(.listen, lease: lease), peer: peer)
            XCTAssertTrue(heard.ok)
            XCTAssertEqual(heard.text, "roll it back")
        }
        XCTAssertEqual(host.spoken.count, 3)
        XCTAssertEqual(host.listenCount, 3)
        XCTAssertTrue(host.prompts.isEmpty, "open mode; and consent is per lease, never per turn")
    }

    func testReleaseEndsTheSession() async {
        let service = makeService(mode: .open)
        let lease = (await service.handle(request(.claim), peer: peer)).lease
        let released = await service.handle(request(.release, lease: lease), peer: peer)
        XCTAssertTrue(released.ok)

        let after = await service.handle(request(.listen, lease: lease), peer: peer)
        XCTAssertEqual(after.reason, .notHolder)
    }

    // The pill is answerable from the moment it is on screen, and `speak` does
    // not return until playback finishes — several seconds during which the
    // accept and deny controls were showing with no continuation behind them.
    // A click in that window resolved the policy and then had nothing to
    // resume, so the answer was dropped and the claim waited out a deadline
    // the user had already answered. From the outside: "the checkmark only
    // works once the prompt finishes."
    func testAnAnswerGivenWhileAloudIsStillTalkingIsNotLost() async {
        let service = makeService(mode: .confirmByVoice)
        host.duringSpeak = { [weak host] in host?.acceptFromPill?() }
        let response = await service.handle(request(.claim), peer: peer)
        XCTAssertTrue(response.ok, "an answer during playback must count")
        XCTAssertNotNil(response.lease)
    }

    // The other half: if the question was answered while it was still being
    // asked, there is nothing left to listen for, and opening the microphone
    // afterwards would be capturing past the decision.
    func testTheMicrophoneDoesNotOpenAfterAnAnswerArrivesDuringPlayback() async {
        let service = makeService(mode: .confirmByVoice)
        host.duringSpeak = { [weak host] in host?.acceptFromPill?() }
        _ = await service.handle(request(.claim), peer: peer)
        XCTAssertFalse(host.listenedForConsent,
                       "consent capture must not start once the prompt is answered")
    }

    // Hang up means "give me my microphone back", not "next, please".
    //
    // Force-release used to clear only the holder, so a queued agent took the
    // microphone about a cooldown later: the user presses the control that
    // exists to stop an agent, and a different agent starts talking. The queue
    // goes with the holder, and anyone parked on a wait is told rather than
    // granted — which is also what the plan asks for, that a waiting agent is
    // answered rather than left hanging.
    func testHangingUpAnswersAParkedAgentInsteadOfGrantingIt() async {
        let service = makeService(mode: .open)
        _ = await service.handle(request(.claim), peer: peer)

        var parkedRequest = BridgeRequest(op: .claim, harness: "codex", pid: 99,
                                          lease: nil, text: nil)
        parkedRequest.name = "release notes"
        parkedRequest.wait = 10
        let waiter = peer
        async let parked = service.handle(parkedRequest, peer: waiter)

        // Long enough for the wait loop to be running rather than still on its
        // first claim, so the hang up lands mid-park — which is the case that
        // used to end with the microphone handed over.
        try? await Task.sleep(nanoseconds: 400_000_000)
        service.forceRelease()

        let response = await parked
        XCTAssertFalse(response.ok, "a parked agent must not be granted by a hang up")
        XCTAssertEqual(response.reason, .denied)
        XCTAssertNil(response.lease)
    }

    // The trash on a session row scopes to that row. Ending the holder is
    // "this conversation is over", not "give me my microphone back" — so the
    // next waiter is promoted once the cooldown passes, rather than being told
    // the user reclaimed the mic.
    func testEndingTheHolderPromotesTheNextWaiter() async {
        let service = makeService(mode: .open)
        let granted = await service.handle(request(.claim), peer: peer)
        guard let lease = granted.lease else { return XCTFail("no lease granted") }

        var parkedRequest = BridgeRequest(op: .claim, harness: "codex", pid: 99,
                                          lease: nil, text: nil)
        parkedRequest.name = "release notes"
        parkedRequest.wait = 10
        let waiter = peer
        async let parked = service.handle(parkedRequest, peer: waiter)
        try? await Task.sleep(nanoseconds: 400_000_000)

        service.endSession(lease)
        clock.advance(5)                       // past the audio cooldown

        let response = await parked
        XCTAssertTrue(response.ok, "ending one session must hand the microphone on, not reclaim it")
        XCTAssertNotNil(response.lease)
    }

    // Trashing a waiter's row must answer that waiter's parked claim — and
    // nobody else's. The first version bumped the reclaim counter, which told
    // every parked agent the user took the microphone back because one of them
    // was dismissed.
    func testEndingAWaiterAnswersItAndOnlyIt() async {
        let service = makeService(mode: .open)
        let granted = await service.handle(request(.claim), peer: peer)
        guard let lease = granted.lease else { return XCTFail("no lease granted") }

        var dismissedRequest = BridgeRequest(op: .claim, harness: "codex", pid: 99,
                                             lease: nil, text: nil)
        dismissedRequest.name = "release notes"
        dismissedRequest.wait = 10
        let waiter = peer
        async let dismissed = service.handle(dismissedRequest, peer: waiter)

        var bystanderRequest = BridgeRequest(op: .claim, harness: "cursor", pid: 77,
                                             lease: nil, text: nil)
        bystanderRequest.name = "writing docs"
        bystanderRequest.wait = 10
        async let bystander = service.handle(bystanderRequest, peer: waiter)
        try? await Task.sleep(nanoseconds: 400_000_000)

        service.endSession("codex#99")

        let dismissedResponse = await dismissed
        XCTAssertFalse(dismissedResponse.ok, "a dismissed waiter must be answered, not left parked")
        XCTAssertEqual(dismissedResponse.reason, .denied)

        // The other waiter keeps its place: once the holder releases and the
        // cooldown passes, the microphone is its.
        _ = await service.handle(request(.release, lease: lease), peer: peer)
        clock.advance(5)
        let bystanderResponse = await bystander
        XCTAssertTrue(bystanderResponse.ok, "dismissing one waiter must not evict the others")
        XCTAssertNotNil(bystanderResponse.lease)
    }

    // The lease ending has to reach the indicator. An accepted prompt leaves
    // the pill up on purpose — the session carries on into it — so if release
    // only changes lease state, the pill stays on screen saying an agent holds
    // the microphone for as long as the app runs. Found by hand: claim, answer,
    // release, and the pill was still there.
    func testReleaseTellsTheHostTheSessionIsOver() async {
        let service = makeService(mode: .open)
        let lease = (await service.handle(request(.claim), peer: peer)).lease
        XCTAssertEqual(host.sessionsEnded, 0)
        _ = await service.handle(request(.release, lease: lease), peer: peer)
        XCTAssertEqual(host.sessionsEnded, 1)
    }

    // The case release cannot cover: the agent dies, or simply never calls
    // again. Every other reap rides in on a bridge call, so the one situation
    // that strands the pill is the one where no more calls are coming.
    func testAnAbandonedLeaseEndsItsSessionWithoutAnotherCall() async {
        let service = makeService(mode: .open)
        _ = await service.handle(request(.claim), peer: peer)
        XCTAssertEqual(host.sessionsEnded, 0)

        // Not yet: a lease inside its TTL is a session, not a leak.
        await service.sweepAndEndFinishedSessions()
        XCTAssertEqual(host.sessionsEnded, 0)

        clock.advance(LeaseConfig.default.leaseTTL + 1)
        await service.sweepAndEndFinishedSessions()
        XCTAssertEqual(host.sessionsEnded, 1)

        // And only once — a swept session must not keep re-ending itself.
        await service.sweepAndEndFinishedSessions()
        XCTAssertEqual(host.sessionsEnded, 1)
    }

    // MARK: what comes back

    func testListenReportsWhichCleanupActuallyRan() async {
        // The Concise rewrite needs Apple Intelligence and the app targets
        // macOS 14+, so an agent has to be told whether it got a summary or a
        // raw transcript rather than assuming.
        host.transcript = AgentTranscript(text: "roll it back", raw: "uh roll it back",
                                          cleanup: .basic)
        let service = makeService(mode: .open)
        let lease = (await service.handle(request(.claim), peer: peer)).lease
        let response = await service.handle(request(.listen, lease: lease), peer: peer)
        XCTAssertEqual(response.cleanup, .basic)
        // And nothing else. The verbatim transcript used to ride along beside
        // the cleaned one — the same sentence twice, on every turn, in a
        // payload the harness pays tokens for.
        XCTAssertEqual(response.text, "roll it back")
    }

    // start → poll → stop. The point of the stream is that an agent can cut in
    // as soon as it has heard enough, so poll must hand back the partial and
    // say whether the user is still talking.
    func testStreamingListenRunsStartPollStop() async {
        let service = makeService(mode: .open)
        let claimed = await service.handle(request(.claim), peer: peer)
        let lease = claimed.lease

        var start = request(.listen, lease: lease)
        start.mode = .start
        let opened = await service.handle(start, peer: peer)
        XCTAssertTrue(opened.ok)
        let session = try? XCTUnwrap(opened.session)
        XCTAssertEqual(host.listenCount, 0, "starting a session must not run a blocking capture")

        var poll = request(.listen, lease: lease)
        poll.mode = .poll
        poll.session = session
        poll.wait = 4
        let heard = await service.handle(poll, peer: peer)
        XCTAssertTrue(heard.ok)
        XCTAssertEqual(heard.text, "roll it")
        XCTAssertEqual(heard.speaking, true)
        XCTAssertEqual(host.polled.first, 4, "the agent's ceiling has to reach the host")

        var stop = request(.listen, lease: lease)
        stop.mode = .stop
        stop.session = session
        let final = await service.handle(stop, peer: peer)
        XCTAssertEqual(final.text, "roll it back")
        XCTAssertEqual(final.cleanup, .concise)
        XCTAssertEqual(host.stopped, [session])
    }

    // A poll ceiling is capped so it cannot outlive the shell that asked.
    func testPollCeilingIsCapped() async {
        let service = makeService(mode: .open)
        let claimed = await service.handle(request(.claim), peer: peer)
        var start = request(.listen, lease: claimed.lease)
        start.mode = .start
        let session = (await service.handle(start, peer: peer)).session

        var poll = request(.listen, lease: claimed.lease)
        poll.mode = .poll
        poll.session = session
        poll.wait = 9999
        _ = await service.handle(poll, peer: peer)
        XCTAssertEqual(host.polled.first, 30)
    }

    func testPollAndStopNeedTheSessionThatStartReturned() async {
        let service = makeService(mode: .open)
        let claimed = await service.handle(request(.claim), peer: peer)
        for mode in [BridgeRequest.ListenMode.poll, .stop] {
            var r = request(.listen, lease: claimed.lease)
            r.mode = mode
            let response = await service.handle(r, peer: peer)
            XCTAssertEqual(response.reason, .badRequest,
                           "\(mode) without a session is a request error, not a silent no-op")
        }
    }

    // MARK: user override

    func testForceReleaseAnswersAnAgentThatIsStillWaiting() async {
        let service = makeService(mode: .confirmByVoice)
        let claim = Task { await service.handle(self.request(.claim), peer: self.peer) }
        try? await Task.sleep(nanoseconds: 60_000_000)

        service.forceRelease()

        let response = await claim.value
        XCTAssertFalse(response.ok, "pulling the plug must not leave the agent hanging to its own timeout")
        XCTAssertEqual(response.reason, .denied)
    }
}
