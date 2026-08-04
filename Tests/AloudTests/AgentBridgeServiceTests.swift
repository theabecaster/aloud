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
        // How many times the pill was told somebody is waiting, and whether the
        // notice was taken down again.
        var agentWaitingNotices = 0
        var agentWaitingCleared = 0
        func noteAgentWaiting() { agentWaitingNotices += 1 }
        func clearAgentWaiting() { agentWaitingCleared += 1 }

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
        // What the last listen was asked to wait, so a test can prove the hold
        // reached the host rather than being clamped away or dropped in the
        // service.
        var heldFor: [TimeInterval] = []
        // Seconds to spend inside `listen` before answering, so a test can put
        // a real await in the middle of a hold and watch what the rest of the
        // service does around it.
        var listenDelay: TimeInterval = 0
        // Fires inside the listen, which is where a hold's time actually
        // passes. Advancing the clock from `duringSpeak` looks equivalent and
        // is not: the service starts counting the wait after the question has
        // been spoken.
        var duringListen: (@MainActor @Sendable () -> Void)?
        func listen(from: Date, holdingFor: TimeInterval) async throws -> AgentTranscript {
            listenCount += 1
            listenFrom = from
            heldFor.append(holdingFor)
            await duringListen?()
            if listenDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(listenDelay * 1_000_000_000))
            }
            if let listenError { throw listenError }
            return transcript
        }

        // Streaming variant. `polled` records what the agent asked for so a
        // test can assert the ceiling was passed through rather than ignored.
        var sessions: [String] = []
        var polled: [TimeInterval] = []
        var stopped: [String] = []
        var partial = "roll it"
        // The streaming session failing to open at all — the engine busy, the
        // model not loaded. Its own catch in the service, and without a seam
        // here nothing could ever reach it.
        var startError: Error?
        func startListenSession() async throws -> String {
            if let startError { throw startError }
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
    // at most one file. `forgetTestDefaults` clears it up; see the note on it
    // for what that can and cannot promise about the file on disk.
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
        forgetTestDefaults(suiteName)
        super.tearDown()
    }

    private func makeService(mode: AgentConsentMode = .open,
                             enabled: Bool = true,
                             harnesses: [String] = ["claude-code"],
                             consent config: ConsentConfig = .default) -> AgentBridgeService {
        let settings = SettingsStore(defaults: defaults)
        settings.experimentalAgentVoice = enabled
        settings.installedHarnesses = harnesses
        settings.agentConsentMode = mode
        let clock = self.clock!
        return AgentBridgeService(leases: LeaseManager(isAlive: { _ in true }),
                                  consent: ConsentPolicy(mode: mode, config: config),
                                  settings: settings,
                                  host: host,
                                  now: { clock.current })
    }

    // The same service, built around a SettingsStore the test keeps hold of.
    //
    // Needed wherever the consent mode has to be tightened *after* a session is
    // already open, which is the only way two of the branches below are ever
    // reached: `makeService` builds its store privately, so a test using it can
    // only ever exercise the mode it started with — which is exactly why the
    // whole consent branch of `listen` had never been executed by anything.
    private func makeService(settings: SettingsStore,
                             consent config: ConsentConfig = .default) -> AgentBridgeService {
        let clock = self.clock!
        return AgentBridgeService(leases: LeaseManager(isAlive: { _ in true }),
                                  consent: ConsentPolicy(mode: settings.agentConsentMode,
                                                         config: config),
                                  settings: settings,
                                  host: host,
                                  now: { clock.current })
    }

    // A store in the shipped default: the gate on, one harness, agents let in
    // on sight.
    private func openSettings() -> SettingsStore {
        let settings = SettingsStore(defaults: defaults)
        settings.experimentalAgentVoice = true
        settings.installedHarnesses = ["claude-code"]
        settings.agentConsentMode = .open
        return settings
    }

    // Wait for something to have happened, rather than for a fixed number of
    // milliseconds to have passed.
    //
    // Most of the tests below drive a claim on one task and answer it from the
    // other, so they need the prompt to be up before they can answer it. A
    // fixed `Task.sleep` is a guess at how long that takes: on a loaded runner
    // it observes a half-built state and asserts against it, and — worse — the
    // test then blocks on `await claim.value` for the whole consent deadline
    // before failing for a reason that has nothing to do with what it is about.
    // Polling with a generous ceiling is right in both directions: it is
    // usually faster than the sleep it replaces, and it cannot lose the race.
    private func waitUntil(_ what: String,
                           timeout: TimeInterval = 10,
                           file: StaticString = #filePath,
                           line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    // A mutable flag a detached task can set and the test can read. `var`
    // capture would copy; this is the smallest thing that does not.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    // What the menu bar and the pill were told, and when. `atListen` is taken
    // from inside the host's `listen`, which is the instant that matters: the
    // pill has to know whose session it is drawing before the microphone opens,
    // not after the whole call is over.
    private final class HolderLog: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [[AgentSession]] = []
        private var listenSnapshot: [AgentSession] = []
        func record(_ sessions: [AgentSession]) {
            lock.lock(); all.append(sessions); lock.unlock()
        }
        var latest: [AgentSession] { lock.lock(); defer { lock.unlock() }; return all.last ?? [] }
        var count: Int { lock.lock(); defer { lock.unlock() }; return all.count }
        func markListenStarted() {
            let now = latest
            lock.lock(); listenSnapshot = now; lock.unlock()
        }
        var atListen: [AgentSession] { lock.lock(); defer { lock.unlock() }; return listenSnapshot }
    }

    private func request(_ op: BridgeOperation, lease: String? = nil,
                         text: String? = nil, name: String = "fixing tests",
                         pid: pid_t = 4242) -> BridgeRequest {
        var request = BridgeRequest(op: op, harness: "claude-code", pid: pid,
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
        await waitUntil("the prompt to come up") { !self.host.prompts.isEmpty }
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
    // rather than seizing the hotkey out from under them — and gives back the
    // lease it had just been granted, or the microphone is stranded on a
    // session that was never allowed to start.
    //
    // Getting here is the whole difficulty, and why this test used to prove
    // nothing: setting the flag before the claim means the *dictation wait loop*
    // at the top of `claim` answers first, and the guard this is named for — the
    // one below the grant, after consent has come back `awaiting` — was never
    // executed by anything in the suite. Deleting it left everything green.
    //
    // So the dictation has to begin while the caller is already past that loop:
    // parked in the queue behind somebody else, with the microphone about to
    // come free.
    func testClaimIsRefusedWhileTheUserIsDictating() async {
        // Open to start with, so the holder gets in without a prompt; tightened
        // before the waiter arrives, so the waiter meets one.
        let settings = openSettings()
        let service = makeService(settings: settings)

        let holder = await service.handle(request(.claim), peer: peer)
        let held = holder.lease
        XCTAssertNotNil(held)

        settings.agentConsentMode = .confirmOnScreen

        var waiting = request(.claim)
        waiting.harness = "codex"
        waiting.pid = 5150
        waiting.wait = 30
        let parked = Task {
            await service.handle(waiting,
                                 peer: BridgeServer.PeerIdentity(pid: 5150, name: "codex"))
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(service.holderHarnessForTesting, "claude-code",
                       "the waiter has to still be parked, or it never reaches the grant")

        // The user starts talking, and only then does the microphone come free.
        host.userDictationInProgress = true
        _ = await service.handle(request(.release, lease: held), peer: peer)
        clock.advance(5)                       // past the audio cooldown

        let response = await parked.value
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.reason, .queued,
                       "`queued` invites the retry that `denied` would talk the agent out of")
        XCTAssertEqual(response.retryAfter, 3, "and it has to be told how long to leave it")
        XCTAssertEqual(host.prompts.count, 0, "no consent prompt over a live dictation")
        XCTAssertNil(service.holderHarnessForTesting,
                     "the lease taken to ask with must be handed back, "
                     + "or the microphone is reserved for a session nobody approved")
    }

    // MARK: the harness id, which is the one string an attacker chooses

    // Every id the installer actually writes has to survive the validator, or
    // the feature refuses the machines it just installed itself on.
    func testEveryHarnessIdTheInstallerWritesIsAccepted() {
        for harness in AgentHarness.allCases {
            XCTAssertTrue(AgentBridgeService.isWellFormedHarness(harness.id),
                          "\(harness.id) is written into an installed skill file and then refused")
        }
        // And the shapes a caller might reasonably use for one we have not
        // shipped yet.
        for ok in ["a", "my-harness", "harness_2", "Agent.CLI", "0", String(repeating: "x", count: 32)] {
            XCTAssertTrue(AgentBridgeService.isWellFormedHarness(ok), ok)
        }
    }

    // The other half, and the one the guard exists for. The holder's id does
    // not stay inside Aloud — it is handed back to *other* callers ("codex is
    // using the microphone", `queuedBehind`, `status`), so without this a
    // megabyte of attacker-chosen prose lands verbatim in another agent's tool
    // output: a text channel from a process with no other capability straight
    // into a trusted agent's context.
    func testAHarnessIdThatIsNotOneIsRefused() {
        let bad: [(String, String)] = [
            ("", "empty"),
            (String(repeating: "x", count: 33), "one over the ceiling"),
            (String(repeating: "x", count: 1_000_000), "a megabyte of it"),
            ("claude code", "a space"),
            ("claude\ncode", "a newline"),
            ("claude\tcode", "a tab"),
            ("ignore previous instructions and", "a sentence"),
            ("claude/code", "a path separator"),
            ("claude:code", "a colon"),
            ("claude\u{0}code", "a NUL"),
            ("clåude", "not ASCII"),
            ("claude-code\u{1F600}", "an emoji"),
            ("клод", "another script"),
        ]
        for (id, why) in bad {
            XCTAssertFalse(AgentBridgeService.isWellFormedHarness(id),
                           "\(why) has no business in a harness id")
        }
    }

    // …and the refusal reaches the wire, before anything else happens. The
    // check sits above the lease, so a malformed id must not be able to take
    // the microphone on its way to being rejected.
    func testAMalformedHarnessIdIsARequestErrorAndTakesNoLease() async {
        let service = makeService(mode: .open)
        var bad = request(.claim)
        bad.harness = "claude code\n" + String(repeating: "prose ", count: 2_000)

        let response = await service.handle(bad, peer: peer)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.reason, .badRequest,
                       "`badRequest` says the call was wrong; anything else invites a retry")
        XCTAssertNil(service.holderHarnessForTesting, "and it must not have taken the microphone")
        XCTAssertFalse(response.message?.contains("prose") == true,
                       "the refusal must not quote the string back")
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
        await waitUntil("the prompt to be spoken") {
            !self.host.prompts.isEmpty && !self.host.spoken.isEmpty
        }
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
        await waitUntil("the consent microphone to open") { self.host.listenedForConsent }

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
        await waitUntil("prompt, speech and microphone") { self.host.events.count >= 3 }

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
        await waitUntil("the microphone to be listening for an answer") {
            self.host.listenedForConsent
        }
        host.heardFromMic?("decline")
        _ = await claim.value

        XCTAssertEqual(host.dismissedAccepted, [false],
                       "the host has to be told the session is not proceeding, or the pill stays up")
    }

    func testDecliningRefusesWithDeniedAndFreesTheLease() async {
        let service = makeService(mode: .confirmOnScreen)
        let claim = Task { await service.handle(self.request(.claim), peer: self.peer) }
        await waitUntil("the prompt to come up") { !self.host.prompts.isEmpty }
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
        await waitUntil("the prompt to come up") { !self.host.prompts.isEmpty }
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
        await waitUntil("the prompt to come up") { !self.host.prompts.isEmpty }
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
        await waitUntil("the second harness's prompt") { self.host.prompts.count == 2 }
        XCTAssertEqual(host.prompts.count, 2, "a different harness still gets to ask")
        service.declineConsent(lease: host.prompts.last?.lease ?? "")
        _ = await second.value
    }

    // The other half of the back-off, and the one that fails silently: it has
    // to LIFT. A typo turning a minute into a decade would ship as "Agent Speak
    // stopped working, no error" — every claim answered `denied` from a refusal
    // the user made once, weeks ago, with nothing anywhere saying so.
    func testTheRefusalBackOffLiftsOnceItHasElapsed() async {
        let service = makeService(mode: .confirmOnScreen)
        let claim = Task { await service.handle(self.request(.claim), peer: self.peer) }
        await waitUntil("the prompt to come up") { !self.host.prompts.isEmpty }
        service.declineConsent(lease: host.prompts.first?.lease ?? "")
        _ = await claim.value

        // Still inside it: the same claimant is answered from memory. Past the
        // 5 s floor every claimant shares, so this is the per-claimant back-off
        // being tested and not the global quiet.
        clock.advance(AgentBridgeService.anyRefusalQuiet + 1)
        let tooSoon = await service.handle(request(.claim), peer: peer)
        XCTAssertEqual(tooSoon.reason, .denied, "the back-off is still in force")
        XCTAssertEqual(host.prompts.count, 1, "and nobody was asked again")

        clock.advance(AgentBridgeService.refusalBackoff + 1)

        let again = Task { await service.handle(self.request(.claim), peer: self.peer) }
        await waitUntil("the second prompt") { self.host.prompts.count == 2 }
        host.acceptFromPill?()
        let response = await again.value
        XCTAssertTrue(response.ok, "the back-off has to end, or the feature never comes back")
        XCTAssertNotNil(response.lease)
    }

    // MARK: nobody answers the prompt
    //
    // The timeout is what stands between a user who walked away and a claim
    // parked forever: the continuation resumes from the pill, from a spoken
    // answer, or from the deadline, and if the deadline is the one that goes
    // wrong there is nothing to notice — the agent's shell simply never
    // returns.

    func testAConsentPromptNobodyAnswersTimesOutRatherThanHangingForever() async {
        let service = makeService(mode: .confirmOnScreen, consent: ConsentConfig(timeout: 0.25))

        let response = await service.handle(request(.claim), peer: peer)

        XCTAssertFalse(response.ok)
        // Not `denied`: the agent has to be able to tell "the user said no"
        // from "nobody was there", because only one of those is worth asking
        // again about.
        XCTAssertEqual(response.reason, .timeout)
        XCTAssertNil(service.holderHarnessForTesting,
                     "an unanswered prompt must not leave the microphone reserved")
        XCTAssertEqual(host.dismissedAccepted, [false], "and the pill comes down with it")
    }

    // The same deadline, reached the other way: the policy's own clock has
    // moved past it, so `check(now:)` hands back the real resolution instead of
    // the fallback above. Both roads lead to `timeout`, and the fallback exists
    // precisely because the second one cannot be relied on.
    func testATimeoutIsStillATimeoutWhenThePolicyClockHasPassedTheDeadline() async {
        let service = makeService(mode: .confirmOnScreen, consent: ConsentConfig(timeout: 0.5))
        let claim = Task { await service.handle(self.request(.claim), peer: self.peer) }
        await waitUntil("the prompt to come up") { !self.host.prompts.isEmpty }
        clock.advance(60)

        let response = await claim.value
        XCTAssertEqual(response.reason, .timeout)
        XCTAssertNil(service.holderHarnessForTesting)
    }

    // MARK: consent asked at `listen`
    //
    // `listen` has its own copy of the consent branch, reached when the user
    // tightens the mode while a session is already open: the grant the claim was
    // made under is dropped, so the verb that already holds the lease has to ask.
    //
    // None of it had ever been executed. Every test above builds its service at
    // one fixed mode, so no session was ever open when the mode changed — and
    // the back-off writes on this path are precisely the ones the code's own
    // comment says were missing: without them `listen` "was the way around" the
    // refusal back-off, able to raise the prompt again on the lease it already
    // holds, as often as it liked, forever.

    func testTighteningTheModeMidSessionMakesListenAsk() async {
        let settings = openSettings()
        let service = makeService(settings: settings)
        let claim = await service.handle(request(.claim), peer: peer)
        let lease = claim.lease
        XCTAssertNotNil(lease)
        XCTAssertTrue(host.prompts.isEmpty, "open mode asks nobody")

        settings.agentConsentMode = .confirmByVoice
        let listening = Task {
            await service.handle(self.request(.listen, lease: lease), peer: self.peer)
        }
        await waitUntil("the prompt the tightened mode owes the user") {
            !self.host.prompts.isEmpty
        }
        host.acceptFromPill?()

        let response = await listening.value
        XCTAssertTrue(response.ok, "a yes here has to let the listen through")
        XCTAssertEqual(host.listenCount, 1)
    }

    // A no given here has to hold here too. Recording the back-off only at
    // `claim` would leave this verb free to put the prompt straight back up on
    // the lease it already holds.
    func testANoAtListenIsRefusedAndBuysQuietFromListenItself() async {
        let settings = openSettings()
        let service = makeService(settings: settings)
        let lease = await service.handle(request(.claim), peer: peer).lease

        settings.agentConsentMode = .confirmByVoice
        let listening = Task {
            await service.handle(self.request(.listen, lease: lease), peer: self.peer)
        }
        await waitUntil("the prompt to come up") { !self.host.prompts.isEmpty }
        service.declineConsent(lease: lease ?? "")

        let denied = await listening.value
        XCTAssertEqual(denied.reason, .denied)
        XCTAssertEqual(host.listenCount, 0, "a refused prompt must not open the microphone")

        // And the next one is answered from that no, rather than with a second
        // prompt over a user who has already said what they think.
        let again = await service.handle(request(.listen, lease: lease), peer: peer)
        XCTAssertEqual(again.reason, .denied)
        XCTAssertNotNil(again.retryAfter, "an agent has to be told how long to stay quiet for")
        XCTAssertEqual(host.prompts.count, 1, "the user must not be asked a second time")
        XCTAssertEqual(host.listenCount, 0)
    }

    // Silence buys the same quiet, for the same reason: a prompt that costs
    // nothing to leave unanswered can simply be raised again, and a prompt on
    // screen re-points the dictation hotkey at "accept".
    func testAPromptNobodyAnswersAtListenAlsoBuysQuiet() async {
        let settings = openSettings()
        let service = makeService(settings: settings, consent: ConsentConfig(timeout: 0.25))
        let lease = await service.handle(request(.claim), peer: peer).lease

        settings.agentConsentMode = .confirmOnScreen
        let timedOut = await service.handle(request(.listen, lease: lease), peer: peer)
        XCTAssertEqual(timedOut.reason, .timeout,
                       "the agent has to tell 'nobody was there' from 'they said no'")
        XCTAssertEqual(host.prompts.count, 1)

        let again = await service.handle(request(.listen, lease: lease), peer: peer)
        XCTAssertEqual(again.reason, .denied)
        XCTAssertNotNil(again.retryAfter)
        XCTAssertEqual(host.prompts.count, 1,
                       "an unanswered prompt that costs nothing gets raised forever")
        XCTAssertEqual(host.listenCount, 0)
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
        // Set from inside the parked task, so "it is still parked" is something
        // this test can actually observe. `parked.isCancelled` cannot fail:
        // nothing here cancels it and `Task.isCancelled` only ever flips on an
        // explicit cancellation, which left the flagship `claim --wait` test
        // with no live assertion at all between the claim and the release.
        let answered = Flag()
        let parked = Task {
            let response = await service.handle(waiting,
                                                peer: BridgeServer.PeerIdentity(pid: 5150,
                                                                                name: "codex"))
            answered.set()
            return response
        }

        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(answered.isSet, "the waiter must still be parked, not already answered")
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

        // Asked for by the id the menu bar itself would use, rather than
        // spelled out here: the row id carries whether the caller could prove
        // which process it belongs to, and a literal in a test is exactly how
        // that stops matching without anything noticing.
        var rows: [AgentSession] = []
        service.onHolderChanged = { rows = $0 }
        service.publishSessionsForTesting()
        guard let codexRow = rows.first(where: { $0.harness == "codex" && !$0.isHolder }) else {
            return XCTFail("the dismissed waiter is not in the session list")
        }
        service.endSession(codexRow.id)

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
        await waitUntil("the prompt to come up") { !self.host.prompts.isEmpty }

        service.forceRelease()

        let response = await claim.value
        XCTAssertFalse(response.ok, "pulling the plug must not leave the agent hanging to its own timeout")
        XCTAssertEqual(response.reason, .denied)
    }

    // MARK: ask
    //
    // `ask` is claim + speak + listen in one call. It exists because those
    // three cost an agent three model turns to put one question to somebody,
    // and an agent weighing that against ending its turn — which is free —
    // chooses to end its turn. Nothing here is new policy, so what these tests
    // are really pinning is that it is the *same* policy: the same refusals,
    // the same ordering, and no lease left behind on any path out.

    private func askRequest(lease: String? = nil,
                            text: String? = "Roll it back, or fix it forward?",
                            end: Bool = false) -> BridgeRequest {
        var request = self.request(.ask, lease: lease, text: text)
        request.end = end ? true : nil
        return request
    }

    func testAskClaimsSpeaksAndListensInOneCall() async {
        let service = makeService(mode: .open)
        let response = await service.handle(askRequest(), peer: peer)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.text, "roll it back")
        XCTAssertEqual(host.spoken, ["Roll it back, or fix it forward?"])
        XCTAssertEqual(host.listenCount, 1)
        // The lease rides back so the next question is one more `ask --lease`
        // rather than a second claim and a second consent prompt.
        XCTAssertNotNil(response.lease)
        XCTAssertEqual(service.holderHarnessForTesting, "claude-code")
    }

    // The ordering that used to be a written rule an agent could get wrong.
    // Opening the microphone before saying anything asks a question nobody
    // knows was asked; inside one verb it is structural instead of advisory.
    func testAskAlwaysSpeaksBeforeItListens() async {
        let service = makeService(mode: .open)
        _ = await service.handle(askRequest(), peer: peer)
        XCTAssertEqual(host.events.filter { $0 == "speak" }.count, 1)
        XCTAssertTrue(host.spoken.count == 1 && host.listenCount == 1)
        XCTAssertEqual(host.events.first, "speak", "nothing reaches the microphone first")
    }

    // The one-question shape: no claim before it, no release after it. This is
    // what takes a question from four commands to one.
    func testAskWithEndHangsUpOnTheWayOut() async {
        let service = makeService(mode: .open)
        let response = await service.handle(askRequest(end: true), peer: peer)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.text, "roll it back")
        XCTAssertNil(response.lease, "there is no session left to carry")
        XCTAssertNil(service.holderHarnessForTesting, "the microphone is free again")
        XCTAssertEqual(host.sessionsEnded, 1, "and the pill came off screen")
    }

    // Consent is per session, so a follow-up inside one costs the user nothing.
    // Charging them a second prompt for the second half of a conversation is
    // the fastest way to have the feature switched off.
    func testAFollowUpAskOnTheSameLeaseAsksTheUserNothingAgain() async {
        let service = makeService(mode: .confirmOnScreen)
        let first = Task { await service.handle(self.askRequest(), peer: self.peer) }
        await waitUntil("the pill's accept control") { self.host.acceptFromPill != nil }
        host.acceptFromPill?()
        let opened = await first.value
        let lease = try? XCTUnwrap(opened.lease)
        XCTAssertEqual(host.prompts.count, 1)

        let second = await service.handle(askRequest(lease: lease), peer: peer)
        XCTAssertTrue(second.ok)
        XCTAssertEqual(host.prompts.count, 1, "the session was already consented to")
        XCTAssertEqual(host.spoken.count, 2)
    }

    // A refusal at the claim is the claim's refusal, verbatim — an agent that
    // has learned the reason codes must not meet a different vocabulary just
    // because it used the one-call form.
    func testAskPassesTheClaimsRefusalStraightBack() async {
        let service = makeService(enabled: false)
        let response = await service.handle(askRequest(), peer: peer)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.reason, .disabled)
        XCTAssertTrue(host.spoken.isEmpty, "a refused claim never reaches the speakers")
    }

    // The failure that would otherwise strand the microphone. Every refusal
    // below the claim is one the skill teaches an agent to accept and move on
    // from, so nobody is coming back with the `release` — the lease has to go
    // with the refusal.
    func testAskReleasesTheSessionItOpenedWhenNobodyAnswers() async {
        let service = makeService(mode: .open)
        host.listenError = AgentListenError.nothingHeard
        let response = await service.handle(askRequest(), peer: peer)

        XCTAssertEqual(response.reason, .timeout)
        XCTAssertNil(service.holderHarnessForTesting,
                     "a session opened by this call does not outlive its own refusal")
        XCTAssertEqual(host.sessionsEnded, 1)
    }

    // …and the mirror image: a lease the caller already held is not this
    // call's to hang up. Tearing it down on a failed question would end a
    // conversation the agent is still in the middle of.
    func testAskLeavesACallersOwnSessionAloneWhenItFails() async {
        let service = makeService(mode: .open)
        let claimed = await service.handle(request(.claim), peer: peer)
        let lease = try? XCTUnwrap(claimed.lease)
        host.listenError = AgentListenError.nothingHeard

        let response = await service.handle(askRequest(lease: lease), peer: peer)
        XCTAssertEqual(response.reason, .timeout)
        XCTAssertEqual(service.holderHarnessForTesting, "claude-code",
                       "the session belongs to the caller, not to this call")
        XCTAssertEqual(host.sessionsEnded, 0)
    }

    func testAskWithNothingToSayIsARequestError() async {
        let service = makeService(mode: .open)
        for text in [nil, "", "   \n"] {
            let response = await service.handle(askRequest(text: text), peer: peer)
            XCTAssertEqual(response.reason, .badRequest)
            XCTAssertNil(service.holderHarnessForTesting,
                         "a malformed request must not take the microphone on its way out")
        }
    }

    // Same rule `claim` enforces, reached through the other door: a session
    // the user cannot see the name of is one they cannot make a decision about.
    // MARK: an agent arriving mid-dictation
    //
    // The user is talking; their session owns the microphone and the hotkey.
    // Refusing is right — but refusing *silently* meant the whole exchange
    // happened where the user could not see it, and they finished their
    // sentence never knowing anything had wanted them.

    func testAnAgentArrivingMidDictationIsRefusedAndTheUserIsTold() async {
        let service = makeService(mode: .open)
        host.userDictationInProgress = true

        let response = await service.handle(request(.claim), peer: peer)

        XCTAssertEqual(response.reason, .queued)
        XCTAssertNil(service.holderHarnessForTesting, "the user keeps their microphone")
        XCTAssertGreaterThan(host.agentWaitingNotices, 0,
                             "the pill has to say somebody is waiting; nothing else can")
    }

    // A caller that said it could wait rides the dictation out instead of
    // giving up. Somebody dictating is somebody who is *there* and about to be
    // free, which makes waiting almost always the right answer.
    func testACallerThatCanWaitRidesOutTheDictation() async {
        let service = makeService(mode: .open)
        host.userDictationInProgress = true
        var request = self.request(.claim)
        request.wait = 30

        let claim = Task { await service.handle(request, peer: self.peer) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(service.holderHarnessForTesting, "still the user's microphone")
        host.userDictationInProgress = false

        let response = await claim.value
        XCTAssertTrue(response.ok, "the moment they stopped, the agent was let in")
        XCTAssertEqual(service.holderHarnessForTesting, "claude-code")
        XCTAssertGreaterThan(host.agentWaitingCleared, 0, "and the notice came down")
    }

    // The gate going off mid-wait ends it, rather than stranding the caller
    // until its own ceiling.
    func testTurningAgentSpeakOffEndsAWaitOnTheUsersDictation() async {
        let settings = SettingsStore(defaults: defaults)
        settings.experimentalAgentVoice = true
        settings.installedHarnesses = ["claude-code"]
        settings.agentConsentMode = .open
        let clock = self.clock!
        let service = AgentBridgeService(leases: LeaseManager(isAlive: { _ in true }),
                                         consent: ConsentPolicy(mode: .open),
                                         settings: settings,
                                         host: host,
                                         now: { clock.current })
        host.userDictationInProgress = true
        var request = self.request(.claim)
        request.wait = 30

        let claim = Task { await service.handle(request, peer: self.peer) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        settings.experimentalAgentVoice = false

        let response = await claim.value
        XCTAssertEqual(response.reason, .disabled)
    }

    // MARK: --hold
    //
    // Holding the microphone for somebody who is not in the room yet. The
    // policy here is small — clamp it, pass it down, keep the lease awake — and
    // each of those three is a silent failure if it is wrong: a hold that does
    // not reach the host is an eight-second wait wearing a ten-minute flag.

    private func heldAsk(_ hold: Double, lease: String? = nil) -> BridgeRequest {
        var request = askRequest(lease: lease)
        request.hold = hold
        return request
    }

    func testTheHoldReachesTheHost() async {
        let service = makeService(mode: .open)
        _ = await service.handle(heldAsk(120), peer: peer)
        XCTAssertEqual(host.heldFor, [120])
    }

    // An agent that asks for an hour does not get one. The ceiling is the
    // user's microphone being reserved, not a number the caller chooses.
    func testAHoldIsClampedToTheCeiling() async {
        let service = makeService(mode: .open)
        _ = await service.handle(heldAsk(99_999), peer: peer)
        XCTAssertEqual(host.heldFor, [AgentBridgeService.maxHold])
    }

    func testANegativeOrAbsentHoldIsNoHoldAtAll() async {
        let service = makeService(mode: .open)
        _ = await service.handle(heldAsk(-5), peer: peer)
        _ = await service.handle(askRequest(), peer: peer)
        XCTAssertEqual(host.heldFor, [0, 0])
    }

    // `waited` is what tells an agent whether real time has passed while it was
    // parked — the difference between acting on the answer straight away and
    // checking its plan first. It may not appear on calls that did not wait,
    // where it would be bytes on every response for nothing.
    func testWaitedIsReportedOnlyWhenItActuallyWaited() async {
        let service = makeService(mode: .open)
        let clock = self.clock!
        // The heartbeat has to be running for this: the lease check *after* the
        // listen reaps on the same clock the wait moved, so without a tick in
        // between a five-minute answer comes back as `notHolder`. That is the
        // production arrangement too — 30s ticks under a 120s TTL — just at a
        // speed a test can observe.
        service.leaseHeartbeat = 0.05
        host.duringListen = { clock.advance(300) }
        host.listenDelay = 0.2

        let held = await service.handle(heldAsk(600), peer: peer)
        XCTAssertTrue(held.ok, "the session survived its own wait")
        XCTAssertEqual(held.waited, 300)

        host.duringListen = nil
        host.listenDelay = 0
        let plain = await service.handle(askRequest(), peer: peer)
        XCTAssertNil(plain.waited, "an ordinary ask waited for nothing and says nothing")
    }

    // The bug a hold walks straight into. Using the lease is normally its own
    // heartbeat, and a hold is one call that can outlive the TTL several times
    // over — so the sweep would reap the holder mid-wait and hand the user's
    // answer back as `notHolder`.
    func testAHeldSessionIsNotReapedWhileItIsStillWaiting() async {
        let service = makeService(mode: .open)
        service.leaseHeartbeat = 0.05
        let clock = self.clock!
        host.listenDelay = 0.5

        let asking = Task { await service.handle(self.heldAsk(600), peer: self.peer) }
        // Far past the 120s TTL, while the call is still in flight.
        try? await Task.sleep(nanoseconds: 200_000_000)
        clock.advance(400)
        try? await Task.sleep(nanoseconds: 150_000_000)
        service.sweep(now: clock.current)
        XCTAssertEqual(service.holderHarnessForTesting, "claude-code",
                       "the session is still in its call and must not be reaped out from under it")

        let response = await asking.value
        XCTAssertTrue(response.ok)
    }

    // …and the heartbeat may not keep a session alive that the user has ended.
    // A hold reserves the microphone for up to ten minutes; "End all" has to
    // beat it, or the control does not mean what it says.
    func testTheHeartbeatDoesNotOutliveTheUserTakingTheMicrophoneBack() async {
        let service = makeService(mode: .open)
        service.leaseHeartbeat = 0.05
        host.listenDelay = 0.4

        let asking = Task { await service.handle(self.heldAsk(600), peer: self.peer) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        service.forceRelease()
        _ = await asking.value

        XCTAssertNil(service.holderHarnessForTesting)
        clock.advance(400)
        service.sweep(now: clock.current)
        XCTAssertNil(service.holderHarnessForTesting)
    }

    // MARK: wait
    //
    // The verb for the second half of the sequence agents actually run: ask,
    // get `timeout` because nobody was at the desk, and now the question has
    // already been spoken and must not be spoken again.

    private func waitRequest(hold: Double? = nil, text: String? = nil,
                             lease: String? = nil) -> BridgeRequest {
        var request = self.request(.wait, lease: lease, text: text)
        request.hold = hold
        request.end = true
        return request
    }

    func testWaitSaysNothingAndParksTheMicrophone() async {
        let service = makeService(mode: .open)
        let response = await service.handle(waitRequest(), peer: peer)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.text, "roll it back")
        XCTAssertTrue(host.spoken.isEmpty,
                      "the question was already asked; asking it again is worse than silence")
        // Waiting is the entire purpose of the verb, so it does not have to be
        // requested — a caller that named no ceiling gets the longest allowed.
        XCTAssertEqual(host.heldFor, [AgentBridgeService.maxHold])
    }

    // The whole sequence this verb was built for, end to end — and the one that
    // failed the first time it was run against the real app.
    //
    // `ask --end` releases, releasing starts the settling cooldown, and the
    // `wait` a beat later was refused with "the microphone is settling". The
    // feature's own previous call was the thing standing in its way, so `wait`
    // queues by default rather than treating a two-second cooldown as a no.
    func testWaitQueuesThroughTheCooldownLeftByTheAskBeforeIt() async {
        let service = makeService(mode: .open)
        let asked = await service.handle(askRequest(end: true), peer: peer)
        XCTAssertTrue(asked.ok)
        XCTAssertNil(service.holderHarnessForTesting, "released, and now settling")

        // The queue loop sleeps in real time and re-claims against the logical
        // clock, so the cooldown only elapses when the test moves it.
        let parked = Task { await service.handle(self.waitRequest(), peer: self.peer) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        clock.advance(30)
        let response = await parked.value

        XCTAssertTrue(response.ok, "wait must ride out the cooldown its own ask created")
        XCTAssertNotEqual(response.reason, .queued)
        XCTAssertEqual(host.listenCount, 2)
    }

    // …but an `ask` in the same position still answers straight away rather
    // than sitting on a microphone somebody else has. The two verbs differ
    // precisely here, and it is the difference that keeps `ask` the fast path.
    func testAskDoesNotQueueByDefault() async {
        let service = makeService(mode: .open)
        // A genuinely different session: same harness, different owner pid, so
        // it is another window of the same tool rather than this one asking
        // twice — which would simply be handed back its own lease.
        _ = await service.handle(request(.claim, name: "someone else", pid: 77), peer: peer)
        XCTAssertEqual(service.holderHarnessForTesting, "claude-code")

        let response = await service.handle(askRequest(), peer: peer)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.reason, .queued, "ask reports a busy microphone rather than waiting on it")
    }

    func testWaitTakesAnExplicitCeiling() async {
        let service = makeService(mode: .open)
        _ = await service.handle(waitRequest(hold: 90), peer: peer)
        XCTAssertEqual(host.heldFor, [90])
    }

    // For the caller that does want it asked again — somebody returning after
    // ten minutes may reasonably have forgotten what they were asked.
    func testWaitRepeatsTheQuestionWhenGivenOne() async {
        let service = makeService(mode: .open)
        _ = await service.handle(waitRequest(text: "Still there? Roll back or fix forward?"),
                                 peer: peer)
        XCTAssertEqual(host.spoken, ["Still there? Roll back or fix forward?"])
    }

    // Same session rules as everything else that can open one: the user has to
    // be able to see whose microphone this is.
    func testWaitWithoutANameIsRefusedLikeAClaim() async {
        let service = makeService(mode: .open)
        var request = waitRequest()
        request.name = nil
        let response = await service.handle(request, peer: peer)
        XCTAssertEqual(response.reason, .badRequest)
        XCTAssertEqual(host.listenCount, 0)
    }

    // A `wait` continuing a session the caller still holds must not re-consent
    // or re-claim — it is the same conversation, moments later.
    func testWaitCarriesOnAnExistingSession() async {
        let service = makeService(mode: .confirmOnScreen)
        let first = Task { await service.handle(self.askRequest(), peer: self.peer) }
        await waitUntil("the pill's accept control") { self.host.acceptFromPill != nil }
        host.acceptFromPill?()
        let opened = await first.value
        let lease = try? XCTUnwrap(opened.lease)

        let parked = await service.handle(waitRequest(lease: lease), peer: peer)
        XCTAssertTrue(parked.ok)
        XCTAssertEqual(host.prompts.count, 1, "the session was already consented to")
        XCTAssertEqual(host.spoken.count, 1, "and nothing new was said")
    }

    func testAskWithoutANameIsRefusedLikeAClaim() async {
        let service = makeService(mode: .open)
        var request = askRequest()
        request.name = nil
        let response = await service.handle(request, peer: peer)
        XCTAssertEqual(response.reason, .badRequest)
        XCTAssertTrue(host.spoken.isEmpty)
    }

    // MARK: the speaker failing
    //
    // Every one of these paths ends with a lease this call opened and an agent
    // that has been told to give up — so if the lease does not go with the
    // refusal, the user's microphone stays claimed by a session that has
    // already stopped thinking about it, until the TTL reaps it minutes later.

    func testASpeakerThatIsBusyIsTransientAndTakesItsLeaseWithIt() async {
        let service = makeService(mode: .open)
        host.speakError = AgentListenError.busy

        let response = await service.handle(askRequest(), peer: peer)

        // `queued`, not `unavailable`: the microphone is open right now, which
        // passes. The skill teaches agents to read `unavailable` as "the
        // feature is gone" and stop using it.
        XCTAssertEqual(response.reason, .queued)
        XCTAssertNotNil(response.retryAfter, "an agent told to try again has to be told when")
        XCTAssertNil(service.holderHarnessForTesting,
                     "the lease this call opened does not outlive its own refusal")
        XCTAssertEqual(host.sessionsEnded, 1, "and the pill came off screen")
        XCTAssertEqual(host.listenCount, 0, "a question nobody heard never reaches the microphone")
    }

    // A voice taken away mid-sentence is not a question that was asked.
    //
    // The speakers are pooled, so the preview button in Settings and an agent's
    // question can be the same instance — and pressing it while an agent is
    // talking cut the question off. The interrupted call returned *normally*,
    // so the bridge answered `ok`, and the agent went straight on to `listen`:
    // the microphone opened on somebody who had been asked nothing and had no
    // idea a turn was waiting on them.
    // A consent prompt raised by `listen` must never land over a live
    // dictation, for the same reason `claim` refuses to: the prompt seizes the
    // hotkey, so the user's key release is swallowed and their commit is lost —
    // and the decline that follows leaves their recorder open behind an idle
    // phase, where the next press adopts it and types the stranded audio.
    func testListenWillNotPromptOverALiveDictation() async {
        // Built from a store the test keeps, so the mode can be tightened on a
        // live service the way the Settings pane does it.
        let settings = SettingsStore(defaults: defaults)
        settings.experimentalAgentVoice = true
        settings.installedHarnesses = ["claude-code"]
        settings.agentConsentMode = .open
        let service = makeService(settings: settings)
        let granted = await service.handle(request(.claim), peer: peer)
        guard let lease = granted.lease else { return XCTFail("no lease granted") }

        // The user starts dictating, and the mode is tightened underneath the
        // session so the next listen has to ask again.
        settings.agentConsentMode = .confirmOnScreen
        host.userDictationInProgress = true

        let response = await service.handle(request(.listen, lease: lease), peer: peer)

        XCTAssertEqual(response.reason, .queued, "transient — the user is busy, not refusing")
        XCTAssertNotNil(response.retryAfter)
        XCTAssertTrue(host.prompts.isEmpty,
                      "no prompt may go up over somebody who is mid-sentence")
        XCTAssertEqual(host.listenCount, 0)
    }

    func testAQuestionCutOffByAnotherVoiceIsNeverReportedAsSpoken() async {
        let service = makeService(mode: .open)
        host.speakError = SpeakerError.superseded

        let response = await service.handle(askRequest(), peer: peer)

        XCTAssertFalse(response.ok, "an interrupted question must not answer ok")
        XCTAssertEqual(response.reason, .queued, "the session is fine — say it again")
        XCTAssertNotNil(response.retryAfter)
        XCTAssertEqual(host.listenCount, 0,
                       "and the microphone never opens on a question nobody heard")
    }

    func testASpeakerThatFailsOutrightIsUnavailableAndAlsoHangsUp() async {
        struct SpeakerGone: Error {}
        let service = makeService(mode: .open)
        host.speakError = SpeakerGone()

        let response = await service.handle(askRequest(), peer: peer)

        XCTAssertEqual(response.reason, .unavailable)
        XCTAssertNil(service.holderHarnessForTesting)
        XCTAssertEqual(host.sessionsEnded, 1)
        XCTAssertEqual(host.listenCount, 0)
    }

    // …and the mirror of it: a `speak` on a session the caller already held is
    // not this call's to hang up. Ending it on a failed sentence would close a
    // conversation the agent is still in the middle of.
    func testAFailedSpeakLeavesACallersOwnSessionAlone() async {
        let service = makeService(mode: .open)
        let lease = (await service.handle(request(.claim), peer: peer)).lease
        host.speakError = AgentListenError.busy

        let response = await service.handle(request(.speak, lease: lease, text: "hi"), peer: peer)

        XCTAssertEqual(response.reason, .queued)
        XCTAssertEqual(response.retryAfter, 3)
        XCTAssertEqual(service.holderHarnessForTesting, "claude-code",
                       "the session belongs to the caller, not to this call")
        XCTAssertEqual(host.sessionsEnded, 0)
    }

    // MARK: the streaming listen going wrong
    //
    // The happy path is covered above. These are the three catches, and the
    // reason code they choose is the whole of what an agent does next.

    // The one that matters most. A streaming session can go away underneath a
    // poll — raced a stop, reset — while the LEASE is perfectly fine. Answering
    // `notHolder` would send the agent back to `claim`, costing it its place in
    // the queue and the user a second consent prompt, for a recovery that is
    // actually just "start the listen again".
    func testPollingASessionTheHostNeverOpenedIsUnavailableNotNotHolder() async {
        let service = makeService(mode: .open)
        let claimed = await service.handle(request(.claim), peer: peer)

        var poll = request(.listen, lease: claimed.lease)
        poll.mode = .poll
        poll.session = "S-never-opened"
        poll.wait = 1
        let response = await service.handle(poll, peer: peer)

        XCTAssertEqual(response.reason, .unavailable,
                       "the lease is fine; only the stream underneath it went away")
        XCTAssertNotEqual(response.reason, .notHolder)
        XCTAssertEqual(service.holderHarnessForTesting, "claude-code",
                       "and the session is still the caller's")
    }

    func testStoppingASessionTheHostNeverOpenedIsAlsoUnavailable() async {
        let service = makeService(mode: .open)
        let claimed = await service.handle(request(.claim), peer: peer)

        var stop = request(.listen, lease: claimed.lease)
        stop.mode = .stop
        stop.session = "S-never-opened"
        let response = await service.handle(stop, peer: peer)

        XCTAssertEqual(response.reason, .unavailable)
        XCTAssertEqual(service.holderHarnessForTesting, "claude-code")
    }

    func testAStreamThatWillNotOpenIsUnavailableAndKeepsTheSession() async {
        let service = makeService(mode: .open)
        let claimed = await service.handle(request(.claim), peer: peer)
        host.startError = AgentListenError.busy

        var start = request(.listen, lease: claimed.lease)
        start.mode = .start
        let response = await service.handle(start, peer: peer)

        XCTAssertEqual(response.reason, .unavailable)
        XCTAssertNil(response.session, "there is no session to hand back")
        XCTAssertEqual(service.holderHarnessForTesting, "claude-code")
    }

    // MARK: telling the rest of the app whose microphone this is

    // The menu bar's session list and the pill's caption both come from
    // `onHolderChanged`, and nothing else ever tells them. `handle` publishes
    // on the way out, which was enough while `claim` was its own round trip —
    // and stopped being enough the moment `ask` collapsed claim, speak and
    // listen into one call, because then nothing is published until the whole
    // conversation is over and the pill spends it calling every session
    // "agent".
    func testTheHolderIsPublishedBeforeTheMicrophoneEverOpens() async {
        let service = makeService(mode: .open)
        let log = HolderLog()
        service.onHolderChanged = { log.record($0) }
        host.duringListen = { log.markListenStarted() }

        let response = await service.handle(askRequest(), peer: peer)
        XCTAssertTrue(response.ok)

        let whenListening = log.atListen
        XCTAssertFalse(whenListening.isEmpty,
                       "nothing had been published by the time the microphone opened")
        let holder = whenListening.first { $0.isHolder }
        XCTAssertEqual(holder?.harness, "claude-code")
        XCTAssertEqual(holder?.name, "fixing tests",
                       "the pill has to be able to say what the session is doing, not just 'agent'")
    }

    // And the session ending is published too, so the row comes back off the
    // list rather than sitting there after the microphone is free.
    func testTheListEmptiesWhenTheSessionEnds() async {
        let service = makeService(mode: .open)
        let log = HolderLog()
        service.onHolderChanged = { log.record($0) }

        _ = await service.handle(askRequest(end: true), peer: peer)

        XCTAssertGreaterThan(log.count, 1, "more than one publication over a whole conversation")
        XCTAssertTrue(log.latest.isEmpty, "the last word is that nobody holds the microphone")
    }

    // MARK: the `--wait` ceiling
    //
    // `--wait N` parks a background shell, and the CLI's own socket timeout is
    // sized against the N the caller asked for. Two independent budgets — one
    // for riding out the user's dictation, one for the queue — meant the shell
    // gave up at N and the app carried on to grant a lease at 2N to a caller
    // that had already gone, which is the exact outcome the ceiling exists to
    // prevent. One budget, spent by both loops.
    func testTheWaitCeilingIsOneBudgetSharedByBothLoops() async {
        let service = makeService(mode: .open)
        // Somebody else holds the microphone, so there is a real queue to sit
        // in once the dictation ends — otherwise the second loop never runs and
        // this proves nothing.
        _ = await service.handle(request(.claim, name: "someone else", pid: 77), peer: peer)
        host.userDictationInProgress = true

        let ceiling: Double = 2
        var waiting = request(.claim, pid: 5150)
        waiting.harness = "codex"
        waiting.wait = ceiling

        let started = Date()
        let parked = Task {
            await service.handle(waiting, peer: BridgeServer.PeerIdentity(pid: 5150, name: "codex"))
        }
        // Three quarters of the budget spent riding out the dictation, leaving
        // the queue loop the remaining quarter and no more.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        host.userDictationInProgress = false
        let response = await parked.value
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(response.reason, .queued)
        XCTAssertEqual(response.queuedBehind, "claude-code")
        XCTAssertGreaterThan(host.agentWaitingNotices, 1, "the dictation loop really did run")
        // Each poll is a real `queuePoll` sleep, so wall-clock time counts them:
        // the whole call may spend at most `Int(wait / queuePoll)` of them.
        //
        // The bound is set against the *bug*, not against the ideal. One budget
        // is ~2 s and two are ~4 s, so anything under 3 s catches a second
        // budget while leaving a full second for a loaded CI runner's sleeps to
        // overshoot. A tighter bound measured the scheduler rather than the
        // code, and duly failed at 2.716 s against 2.7 on a busy machine.
        XCTAssertLessThan(elapsed, 3.0,
                          "the two loops shared one budget of \(Int(ceiling / AgentBridgeService.queuePoll)) polls")
    }
}
