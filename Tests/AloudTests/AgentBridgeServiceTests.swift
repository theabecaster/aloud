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

        func speak(_ text: String) async throws {
            if let speakError { throw speakError }
            spoken.append(text)
        }
        func presentConsent(_ prompt: ConsentPrompt) async { prompts.append(prompt) }
        func dismissConsent() async { dismissals += 1 }
        func listen(from: Date) async throws -> AgentTranscript {
            listenCount += 1
            listenFrom = from
            if let listenError { throw listenError }
            return transcript
        }
    }

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var host: FakeHost!

    override func setUp() {
        super.setUp()
        suiteName = "aloud-bridge-service-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        host = FakeHost()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeService(mode: AgentConsentMode = .open,
                             enabled: Bool = true,
                             harnesses: [String] = ["claude-code"]) -> AgentBridgeService {
        let settings = SettingsStore(defaults: defaults)
        settings.experimentalAgentVoice = enabled
        settings.installedHarnesses = harnesses
        settings.agentConsentMode = mode
        return AgentBridgeService(leases: LeaseManager(isAlive: { _ in true }),
                                  consent: ConsentPolicy(mode: mode),
                                  settings: settings,
                                  host: host)
    }

    private func request(_ op: BridgeOperation, lease: String? = nil,
                         text: String? = nil) -> BridgeRequest {
        BridgeRequest(op: op, harness: "claude-code", pid: 4242, lease: lease, text: text)
    }

    private var peer: BridgeServer.PeerIdentity {
        BridgeServer.PeerIdentity(pid: 4242, name: "claude")
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

        // And the microphone is free for someone else immediately.
        let after = await service.handle(request(.claim), peer: peer)
        XCTAssertNotEqual(after.reason, .queued)
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
        XCTAssertEqual(response.raw, "uh roll it back")
    }

    // Poll mode is defined in the protocol but not implemented. Behaving like
    // blocking would strand an agent waiting for updates a one-shot call will
    // never send, so it is refused out loud.
    func testUnimplementedPollModeIsRefusedRatherThanFakingBlocking() async {
        let service = makeService(mode: .open)
        let lease = (await service.handle(request(.claim), peer: peer)).lease
        var poll = request(.listen, lease: lease)
        poll.mode = .poll
        let response = await service.handle(poll, peer: peer)
        XCTAssertEqual(response.reason, .badRequest)
        XCTAssertEqual(host.listenCount, 0)
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
