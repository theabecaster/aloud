import Foundation

// The policy layer: everything the bridge decides before any audio happens.
//
// Note the messages here are deliberately NOT localized. They travel in JSON
// to an agent, not to a person: the `reason` code is what an agent keys on and
// `message` is the human-readable annotation a developer sees in a log. A
// translated one would hand Spanish prose to something reasoning in English.
// User-facing text for this feature lives in the UI and the spoken prompt,
// both of which are localized.
//
// BridgeServer knows sockets and nothing else; this knows the gate, the lease,
// consent and refusals, and nothing about sockets. Audio and the indicator live
// behind `AgentVoiceHost`, so every rule here is testable without a microphone,
// a model, or a GUI.

// What the running app has to provide for an agent session to actually happen.
// Implemented by DictationController; faked in tests.
protocol AgentVoiceHost: AnyObject, Sendable {
    // Say something out loud. Returns when playback has finished — the
    // half-duplex gate depends on that being true, not approximately true.
    func speak(_ text: String) async throws

    // Put a pending consent request on the indicator, or take it down. Mode 2
    // draws accept/deny controls; mode 3 shows the same prompt while it is
    // spoken, so the user can also just click.
    // `onHeard` is how a spoken answer reaches the policy: in confirm-by-voice
    // the host opens the microphone for the prompt and reports what it hears.
    // Without it that mode has no ears — the policy can classify an utterance
    // perfectly and never be handed one.
    func presentConsent(_ prompt: ConsentPrompt,
                        onAccept: @escaping () -> Void,
                        onDecline: @escaping () -> Void,
                        onHeard: @escaping (String) -> Void) async
    // `accepted` decides whether the pill carries on into the session or comes
    // off screen. A refused or expired prompt that only changes phase leaves an
    // agent indicator sitting there forever.
    // Opened only after the prompt has finished playing. `speak` returns when
    // playback ends, so ordering is the whole half-duplex gate here.
    func beginConsentCapture() async
    func dismissConsent(accepted: Bool) async

    // The session is over — released, force-released, or reaped. The indicator
    // has to be told, because nothing else will: an accepted prompt leaves the
    // pill on screen deliberately (the session carries on into it) and every
    // way a lease can end changes only lease state. Without this the pill sits
    // there for the rest of the app's life, saying an agent has the microphone
    // long after that stopped being true.
    func endAgentSession() async

    // Capture and transcribe until the speaker stops. `from` is the instant
    // consent was granted: nothing captured before it is in scope, which is
    // what keeps a pre-consent buffer out of the agent's hands.
    func listen(from: Date) async throws -> AgentTranscript

    // The streaming variant: open a session, ask it what it has heard so far,
    // end it. `poll` returns the moment the transcript changes so an agent
    // watching a long answer is not charged a model turn per look.
    func startListenSession() async throws -> String
    func pollListenSession(id: String, waitingUpTo seconds: TimeInterval) async throws
        -> (text: String, speaking: Bool, silentFor: TimeInterval?)
    func stopListenSession(id: String) async throws -> AgentTranscript
}

struct AgentTranscript: Sendable {
    let text: String            // after whatever cleanup this Mac can do
    let raw: String             // verbatim
    let cleanup: BridgeResponse.Cleanup
}

@MainActor
final class AgentBridgeService {
    private let leases: LeaseManager
    private let consent: ConsentPolicy
    private let settings: SettingsStore
    private weak var host: AgentVoiceHost?
    private let now: () -> Date

    // Consent resolves from three directions — the pill, a spoken answer, or
    // the deadline passing — while `claim` is parked waiting for it. One
    // continuation per outstanding prompt, resumed exactly once.
    private var pendingConsent: [String: CheckedContinuation<ConsentResolution, Never>] = [:]

    // A harness that was just refused cannot ask again straight away.
    // The installed instructions tell agents that `denied` means this request
    // only and not to retry-loop, but instructions are not enforcement: an
    // agent that ignores them could re-prompt a user who said no, over and
    // over, which is exactly the behaviour that gets a feature switched off for
    // good. Saying no has to actually buy quiet.
    private var refusedUntil: [String: Date] = [:]
    static let refusalBackoff: TimeInterval = 60

    // How long a `claim --wait` may park. Deliberately short of any plausible
    // harness command timeout: a wait that outlives the shell holding it is a
    // lease granted to nobody, and the microphone would sit reserved for a
    // caller that has already gone.
    static let maxQueueWait: TimeInterval = 300
    static let queuePoll: TimeInterval = 0.25

    init(leases: LeaseManager = LeaseManager(),
         consent: ConsentPolicy = ConsentPolicy(),
         settings: SettingsStore = .shared,
         host: AgentVoiceHost? = nil,
         now: @escaping () -> Date = Date.init) {
        self.leases = leases
        self.consent = consent
        self.settings = settings
        self.host = host
        self.now = now
        self.consent.mode = settings.agentConsentMode
    }

    func attach(host: AgentVoiceHost) { self.host = host }

    // Test seam: who holds the microphone right now.
    var holderHarnessForTesting: String? { leases.holder?.harness }

    // MARK: dispatch

    func handle(_ request: BridgeRequest, peer: BridgeServer.PeerIdentity) async -> BridgeResponse {
        // The experimental gate short-circuits everything. `status` is the one
        // exception: an agent has to be able to discover that voice is off
        // without that discovery itself being refused.
        guard settings.agentVoiceAvailable || request.op == .status else {
            return .failure(.disabled, "Agent Speak is turned off in Aloud.")
        }
        leases.enabled = settings.agentVoiceAvailable
        consent.mode = settings.agentConsentMode

        // Every path that can take or give up a lease leaves through here, so
        // the menu bar is told once rather than at four call sites that would
        // eventually disagree.
        // A session's job moves on, so any later call may carry a new name.
        // Deliberately not fatal when it is malformed: a bad label is no
        // reason to refuse a speak that is otherwise fine, and the claim that
        // opened the session already enforced the rule.
        if request.op != .claim, let lease = request.lease,
           case .success(let renamed) = SessionName.validate(request.name) {
            leases.rename(lease: lease, to: renamed)
        }

        defer { publishHolder() }
        switch request.op {
        case .status:  return status()
        case .claim:   return await claim(request, peer: peer)
        case .release: return await release(request)
        case .speak:   return await speak(request)
        case .listen:  return await listen(request)
        }
    }

    // MARK: status — never opens the microphone

    private func status() -> BridgeResponse {
        var response = BridgeResponse.success()
        response.enabled = settings.agentVoiceAvailable
        response.harnesses = settings.installedHarnesses
        response.holder = leases.holder?.harness
        response.voice = NeuralSpeaker().modelIsDownloaded ? .enhanced : .system
        if !settings.agentVoiceAvailable {
            response.ok = false
            response.reason = .disabled
            response.message = "Agent Speak is turned off in Aloud."
        }
        return response
    }

    // MARK: claim

    // Consent is asked for here, once, and the answer covers every listen in
    // the session. Blocking until the user answers is deliberate: it is bounded
    // by the consent timeout, which sits under the harness's command timeout.
    private func claim(_ request: BridgeRequest,
                       peer: BridgeServer.PeerIdentity) async -> BridgeResponse {
        // The socket peer is the CLI process, which exits microseconds after
        // this call — so it is exactly the wrong thing to key liveness on.
        // Using it made every lease dead on arrival: claim succeeded, and the
        // next call in the same conversation was refused as notHolder because
        // the "owner" had already gone.
        //
        // Liveness therefore watches the pid the caller names as its own
        // long-lived process, and `noOwnerPid` (the honest answer from a CLI
        // that cannot know one) means TTL-only. The peer stays what it always
        // was — corroboration for the name we show the user, never authority
        // over the session's lifetime.
        let pid = request.pid > 0 ? request.pid : LeaseManager.noOwnerPid
        let at = now()

        // A session that will not say what it is doing cannot be shown to the
        // user, and the whole point of the name is that it is there before the
        // microphone opens rather than after somebody asks who is talking.
        let name: String
        switch SessionName.validate(request.name) {
        case .success(let valid): name = valid
        case .failure(let why):   return .failure(.badRequest, why.message)
        }

        if let until = refusedUntil[request.harness], at < until {
            var response = BridgeResponse.failure(.denied, "The user declined.")
            response.retryAfter = until.timeIntervalSince(at)
            return response
        }

        // `--wait N` parks here until the turn comes. An agent cannot be pushed
        // to between CLI calls — the connection closes after every one — but it
        // CAN hold one open, which is the same thing from its side: run the
        // command in a background shell and it exits when the microphone is
        // yours. Polling would cost a model turn per look; this costs none.
        //
        // Bounded by the caller's own ceiling, which must stay under the
        // harness's command timeout (§7.3), so a wait can never outlive the
        // shell that is holding it.
        // Counted in polls rather than measured against `now()`. The sleeping
        // here is real time while `now()` is the injectable logical clock, and
        // mixing the two makes the ceiling unreachable whenever the clock is
        // held still — which is exactly what a test does, and what hung one.
        let requested = min(max(request.wait ?? 0, 0), Self.maxQueueWait)
        let pollsRemaining = Int(requested / Self.queuePoll)

        var outcome = leases.claim(harness: request.harness, pid: pid, name: name, now: at)
        if pollsRemaining > 0 {
            var polls = 0
            let reclaimsAtEntry = reclaims
            while case .queued = outcome, polls < pollsRemaining {
                polls += 1
                try? await Task.sleep(nanoseconds: UInt64(Self.queuePoll * 1_000_000_000))
                // The gate going off mid-wait must end it, not strand the
                // caller until its ceiling.
                guard settings.agentVoiceAvailable else {
                    return .failure(.disabled, "Agent Speak is turned off in Aloud.")
                }
                // Nor may it outlive the user taking the microphone back. A
                // wait that survived that would hand the mic to this caller
                // moments after somebody pressed hang up, which is the one
                // outcome that control exists to prevent.
                guard reclaims == reclaimsAtEntry else {
                    return .failure(.denied, "The user took the microphone back.")
                }
                leases.enabled = true
                outcome = leases.claim(harness: request.harness, pid: pid, name: name, now: now())
            }
        }

        switch outcome {
        case .disabled:
            return .failure(.disabled, "Agent Speak is turned off in Aloud.")

        case .queued(let position, let reason):
            var response = BridgeResponse.failure(.queued, queueMessage(reason))
            response.position = position
            if case .busy(let holder) = reason { response.queuedBehind = holder }
            response.retryAfter = position <= 1 ? 2 : 5
            return response

        case .granted(let lease):
            switch consent.request(lease: lease,
                                   harness: request.harness,
                                   name: name,
                                   installedHarnesses: settings.installedHarnesses.count,
                                   now: at) {
            case .granted:
                var response = BridgeResponse.success()
                response.lease = lease
                return response

            case .awaiting(let prompt):
                let resolution = await ask(prompt)
                switch resolution {
                case .accepted:
                    var response = BridgeResponse.success()
                    response.lease = lease
                    return response
                case .denied:
                    // No point holding a lease the user just refused, and no
                    // asking again for a while.
                    refusedUntil[request.harness] = now().addingTimeInterval(Self.refusalBackoff)
                    leases.release(lease: lease, now: now())
                    return .failure(.denied, "The user declined.")
                case .timedOut:
                    leases.release(lease: lease, now: now())
                    return .failure(.timeout, "Nobody answered.")
                case .unrecognized, .ignored:
                    leases.release(lease: lease, now: now())
                    return .failure(.timeout, "Nobody answered.")
                }
            }
        }
    }

    private func queueMessage(_ reason: QueueReason) -> String {
        switch reason {
        case .busy(let holder): return "\(holder) is using the microphone."
        case .cooldown: return "The microphone is settling — try again in a moment."
        }
    }

    // Show the prompt, speak it when the mode says to, and wait for whichever
    // of the three answers arrives first.
    private func ask(_ prompt: ConsentPrompt) async -> ConsentResolution {
        // The pill's accept/deny are a third way to answer, alongside a spoken
        // reply and the deadline. Whichever lands first wins; the rest are
        // ignored because the continuation resumes exactly once.
        let lease = prompt.lease
        await host?.presentConsent(prompt,
                                   onAccept: { [weak self] in self?.acceptConsent(lease: lease) },
                                   onDecline: { [weak self] in self?.declineConsent(lease: lease) },
                                   onHeard: { [weak self] said in
                                       self?.heardConsent(said, lease: lease)
                                   })
        // The prompt is answerable from the instant it is on screen, which
        // means the continuation has to exist before anything is spoken.
        // Speaking first looks harmless and is not: `speak` does not return
        // until playback finishes, so for those several seconds the pill was
        // showing accept and deny controls with nothing behind them. A click
        // in that window resolved the policy — clearing the pending prompt and
        // recording the grant — and then found no continuation to resume, so
        // the answer was dropped and the user's claim waited out a deadline
        // they had already answered. Reported as "the checkmark only works
        // once the prompt finishes", which is exactly what it looked like.
        let deadline = prompt.deadline
        let resolution = await withCheckedContinuation { (continuation: CheckedContinuation<ConsentResolution, Never>) in
            pendingConsent[lease] = continuation
            if prompt.mode == .confirmByVoice {
                Task { [weak self] in
                    // Spoken through whichever voice is available. A failure
                    // here is not fatal on its own — the pill is still showing
                    // the same words — but it does mean a user looking away
                    // never learns they were asked.
                    try? await self?.host?.speak(prompt.text)
                    // Answered while we were still talking: there is nothing
                    // left to listen for, and opening the microphone now would
                    // be capturing after the decision was made.
                    guard let self, self.pendingConsent[lease] != nil else { return }
                    // Only now. Opening the microphone before playback ends
                    // means Aloud transcribes its own prompt and the user's
                    // reply arrives glued to the end of it — "…say yes or no.
                    // Yes." — which is correctly refused as not-an-answer, so
                    // speaking never worked at all.
                    await self.host?.beginConsentCapture()
                }
            }
            Task { [weak self] in
                let wait = deadline.timeIntervalSince(self?.now() ?? Date())
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                self?.timeOutConsent(lease: lease)
            }
        }
        if case .accepted = resolution {
            await host?.dismissConsent(accepted: true)
        } else {
            await host?.dismissConsent(accepted: false)
        }
        return resolution
    }

    // MARK: consent answers, from the GUI

    func acceptConsent(lease: String) {
        let resolution = consent.accept(lease: lease, now: now())
        note("pill accept → \(resolution)")
        resolve(lease, resolution)
    }

    func declineConsent(lease: String) {
        let resolution = consent.decline(lease: lease, now: now())
        note("pill decline → \(resolution)")
        resolve(lease, resolution)
    }

    private func note(_ what: String) {
        FileHandle.standardError.write(Data("[consent] \(what)\n".utf8))
    }

    // A spoken answer. `unrecognized` deliberately does not resolve: babble
    // keeps the prompt pending on the same deadline rather than buying time or
    // counting as an answer.
    func heardConsent(_ utterance: String, lease: String) {
        let resolution = consent.heard(utterance, lease: lease, now: now())
        if case .unrecognized = resolution { return }
        if case .ignored = resolution { return }
        resolve(lease, resolution)
    }

    private func timeOutConsent(lease: String) {
        guard pendingConsent[lease] != nil else { return }
        guard let resolution = consent.check(now: now()) else { return }
        resolve(lease, resolution)
    }

    private func resolve(_ lease: String, _ resolution: ConsentResolution) {
        guard let continuation = pendingConsent.removeValue(forKey: lease) else { return }
        continuation.resume(returning: resolution)
    }

    // MARK: release

    private func release(_ request: BridgeRequest) async -> BridgeResponse {
        guard let lease = request.lease else {
            return .failure(.badRequest, "release needs the lease it is releasing.")
        }
        consent.endLease(lease)
        leases.release(lease: lease, now: now())
        await host?.endAgentSession()
        return .success()
    }

    // MARK: speak

    private func speak(_ request: BridgeRequest) async -> BridgeResponse {
        guard let text = request.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.badRequest, "speak needs something to say.")
        }
        guard let lease = request.lease else {
            return .failure(.badRequest, "speak needs a lease — claim one first.")
        }
        if let refusal = validate(lease) { return refusal }
        guard let host else { return .failure(.unavailable, "Aloud isn't ready.") }

        do {
            try await host.speak(text)
            return .success()
        } catch {
            return .failure(.unavailable, error.localizedDescription)
        }
    }

    // MARK: listen

    private func listen(_ request: BridgeRequest) async -> BridgeResponse {
        guard let lease = request.lease else {
            return .failure(.badRequest, "listen needs a lease — claim one first.")
        }
        if let refusal = validate(lease) { return refusal }
        guard let host else { return .failure(.unavailable, "Aloud isn't ready.") }

        // Ask the policy rather than consulting a cached flag. It answers
        // uniformly for every mode — open grants outright, an existing
        // per-lease grant passes straight through, and a mode the user
        // tightened mid-session correctly asks again instead of coasting on
        // permission given under the old one.
        let grant: ConsentGrant
        switch consent.request(lease: lease,
                               harness: request.harness,
                               name: leases.holder?.name ?? request.harness,
                               installedHarnesses: settings.installedHarnesses.count,
                               now: now()) {
        case .granted(let granted):
            grant = granted
        case .awaiting(let prompt):
            switch await ask(prompt) {
            case .accepted(let granted, _):
                grant = granted
            case .denied:
                return .failure(.denied, "The user declined.")
            case .timedOut, .unrecognized, .ignored:
                return .failure(.timeout, "Nobody answered.")
            }
        }

        // Only the blocking mode exists today. The poll trio is defined in the
        // protocol and refused explicitly rather than silently behaving like
        // blocking, which would strand an agent waiting for updates that a
        // one-shot call is never going to send.
        switch request.mode ?? .blocking {
        case .blocking:
            do {
                // The grant carries the boundary: nothing captured before
                // consent is in scope, which is what keeps a pre-consent
                // buffer out of the agent's hands.
                let transcript = try await host.listen(from: grant.streamStartsAt)
                var response = BridgeResponse.success()
                response.text = transcript.text
                response.raw = transcript.raw
                response.cleanup = transcript.cleanup
                return response
            } catch AgentListenError.nothingHeard {
                // Not a malfunction, and specifically not `unavailable` — that
                // reads as "Aloud isn't running" and invites an agent to retry
                // or give up on the feature. Nobody spoke, which is the same
                // shape as a consent prompt nobody answered.
                return .failure(.timeout, "Didn't hear anything.")
            } catch {
                return .failure(.unavailable, error.localizedDescription)
            }
        case .start:
            do {
                var response = BridgeResponse.success()
                response.session = try await host.startListenSession()
                return response
            } catch {
                return .failure(.unavailable, error.localizedDescription)
            }

        case .poll:
            guard let session = request.session else {
                return .failure(.badRequest, "poll needs the session that start returned.")
            }
            do {
                // Capped well under the harness's command timeout: a poll that
                // outlives the shell asking it returns into nothing.
                let heard = try await host.pollListenSession(id: session,
                                                             waitingUpTo: min(request.wait ?? 5, 30))
                var response = BridgeResponse.success()
                response.session = session
                response.text = heard.text
                response.speaking = heard.speaking
                response.silentFor = heard.silentFor
                return response
            } catch {
                return .failure(.notHolder, error.localizedDescription)
            }

        case .stop:
            guard let session = request.session else {
                return .failure(.badRequest, "stop needs the session that start returned.")
            }
            do {
                let transcript = try await host.stopListenSession(id: session)
                var response = BridgeResponse.success()
                response.text = transcript.text
                response.raw = transcript.raw
                response.cleanup = transcript.cleanup
                return response
            } catch {
                return .failure(.unavailable, error.localizedDescription)
            }
        }
    }

    // MARK: lease checks

    private func validate(_ lease: String) -> BridgeResponse? {
        switch leases.validate(lease: lease, now: now()) {
        case .success:
            return nil
        case .failure(.disabled):
            return .failure(.disabled, "Agent Speak is turned off in Aloud.")
        case .failure(.notHolder):
            // Expired, reaped, or never theirs. Distinct from `queued`: there
            // is nothing to wait for, the session is simply over.
            return .failure(.notHolder, "That session has ended — claim again.")
        }
    }

    // MARK: user override

    // The menu bar pulling the plug. Ends the session and answers any prompt
    // still parked on it, so a waiting agent gets a refusal instead of hanging
    // until its own timeout.
    // Told, not polled: the menu bar's way out of a stuck session has to be
    // there the moment a lease is taken, not up to five seconds later.
    var onHolderChanged: (([AgentSession]) -> Void)?

    // Bumped whenever the user takes the microphone back. A parked `--wait`
    // claim is a polling loop, so clearing the queue alone would not stop it —
    // it would simply re-enqueue on its next poll and take the microphone the
    // user just reclaimed. This is how it learns the answer changed.
    private var reclaims = 0

    private func publishHolder() {
        onHolderChanged?(leases.sessions)
    }

    // Reaping is lazy everywhere else — `claim`, `validate` and `release` reap
    // on the way in — which is right for lease *state* and wrong for the pill.
    // An agent that dies or forgets to release leaves the indicator on screen
    // claiming it has the microphone, and with nobody calling the bridge there
    // is nothing to trigger the reap that would take it down. The user is left
    // looking at a session that ended minutes ago.
    //
    // Returns whether a holder went away, so the caller can drive the UI. Pure
    // and clock-injected like everything else here, so the timer that normally
    // calls it is not required to test it.
    @discardableResult
    func sweep(now moment: Date) -> Bool {
        let had = leases.holder != nil
        leases.reap(now: moment)
        return had && leases.holder == nil
    }

    func sweepAndEndFinishedSessions() async {
        guard sweep(now: now()) else { return }
        publishHolder()
        await host?.endAgentSession()
    }

    // End one named session — the menu bar's list, where more than one wants
    // the microphone. Ending the holder is the hang up; ending a waiter simply
    // takes it out of the queue, and it will be told when it next asks.
    func endSession(_ id: String) {
        if leases.holder?.id == id {
            forceRelease()
            return
        }
        reclaims += 1
        leases.dropQueued(id: id)
        publishHolder()
    }

    func forceRelease() {
        reclaims += 1
        if let lease = leases.holder?.id {
            resolve(lease, .denied(preConsentAudio: .discarded))
            consent.endLease(lease)
        }
        leases.forceRelease(now: now())
        publishHolder()
        Task { [weak self] in await self?.host?.endAgentSession() }
    }
}
