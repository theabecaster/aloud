import Foundation

// The policy layer: everything the bridge decides before any audio happens.
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
    func presentConsent(_ prompt: ConsentPrompt) async
    func dismissConsent() async

    // Capture and transcribe until the speaker stops. `from` is the instant
    // consent was granted: nothing captured before it is in scope, which is
    // what keeps a pre-consent buffer out of the agent's hands.
    func listen(from: Date) async throws -> AgentTranscript
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

    // MARK: dispatch

    func handle(_ request: BridgeRequest, peer: BridgeServer.PeerIdentity) async -> BridgeResponse {
        // The experimental gate short-circuits everything. `status` is the one
        // exception: an agent has to be able to discover that voice is off
        // without that discovery itself being refused.
        guard settings.agentVoiceAvailable || request.op == .status else {
            return .failure(.disabled, loc("Voice is turned off in Aloud."))
        }
        leases.enabled = settings.agentVoiceAvailable
        consent.mode = settings.agentConsentMode

        switch request.op {
        case .status:  return status()
        case .claim:   return await claim(request, peer: peer)
        case .release: return release(request)
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
            response.message = loc("Voice is turned off in Aloud.")
        }
        return response
    }

    // MARK: claim

    // Consent is asked for here, once, and the answer covers every listen in
    // the session. Blocking until the user answers is deliberate: it is bounded
    // by the consent timeout, which sits under the harness's command timeout.
    private func claim(_ request: BridgeRequest,
                       peer: BridgeServer.PeerIdentity) async -> BridgeResponse {
        // Prefer the kernel's view of who is calling over the self-reported
        // pid: an agent that lies about its pid would otherwise get a lease
        // that outlives it, since reaping is liveness-based.
        let pid = peer.isKnown ? peer.pid : request.pid
        let at = now()

        switch leases.claim(harness: request.harness, pid: pid, now: at) {
        case .disabled:
            return .failure(.disabled, loc("Voice is turned off in Aloud."))

        case .queued(let position, let reason):
            var response = BridgeResponse.failure(.queued, queueMessage(reason))
            response.position = position
            if case .busy(let holder) = reason { response.queuedBehind = holder }
            response.retryAfter = position <= 1 ? 2 : 5
            return response

        case .granted(let lease):
            switch consent.request(lease: lease,
                                   harness: request.harness,
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
                    // No point holding a lease the user just refused.
                    leases.release(lease: lease, now: now())
                    return .failure(.denied, loc("The user declined."))
                case .timedOut:
                    leases.release(lease: lease, now: now())
                    return .failure(.timeout, loc("Nobody answered."))
                case .unrecognized, .ignored:
                    leases.release(lease: lease, now: now())
                    return .failure(.timeout, loc("Nobody answered."))
                }
            }
        }
    }

    private func queueMessage(_ reason: QueueReason) -> String {
        switch reason {
        case .busy(let holder): return loc("%@ is using the microphone.", holder)
        case .cooldown: return loc("The microphone is settling — try again in a moment.")
        }
    }

    // Show the prompt, speak it when the mode says to, and wait for whichever
    // of the three answers arrives first.
    private func ask(_ prompt: ConsentPrompt) async -> ConsentResolution {
        await host?.presentConsent(prompt)
        if prompt.mode == .confirmByVoice {
            // Spoken through whichever voice is available. A failure here is
            // not fatal on its own — the pill is still showing the same words —
            // but it does mean a user looking away never learns they were asked.
            try? await host?.speak(prompt.text)
        }

        let deadline = prompt.deadline
        let lease = prompt.lease
        let resolution = await withCheckedContinuation { (continuation: CheckedContinuation<ConsentResolution, Never>) in
            pendingConsent[lease] = continuation
            Task { [weak self] in
                let wait = deadline.timeIntervalSince(self?.now() ?? Date())
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                self?.timeOutConsent(lease: lease)
            }
        }
        await host?.dismissConsent()
        return resolution
    }

    // MARK: consent answers, from the GUI

    func acceptConsent(lease: String) { resolve(lease, consent.accept(lease: lease, now: now())) }
    func declineConsent(lease: String) { resolve(lease, consent.decline(lease: lease, now: now())) }

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

    private func release(_ request: BridgeRequest) -> BridgeResponse {
        guard let lease = request.lease else {
            return .failure(.badRequest, loc("release needs the lease it is releasing."))
        }
        consent.endLease(lease)
        leases.release(lease: lease, now: now())
        return .success()
    }

    // MARK: speak

    private func speak(_ request: BridgeRequest) async -> BridgeResponse {
        guard let text = request.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.badRequest, loc("speak needs something to say."))
        }
        guard let lease = request.lease else {
            return .failure(.badRequest, loc("speak needs a lease — claim one first."))
        }
        if let refusal = validate(lease) { return refusal }
        guard let host else { return .failure(.unavailable, loc("Aloud isn't ready.")) }

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
            return .failure(.badRequest, loc("listen needs a lease — claim one first."))
        }
        if let refusal = validate(lease) { return refusal }
        guard let host else { return .failure(.unavailable, loc("Aloud isn't ready.")) }

        // Ask the policy rather than consulting a cached flag. It answers
        // uniformly for every mode — open grants outright, an existing
        // per-lease grant passes straight through, and a mode the user
        // tightened mid-session correctly asks again instead of coasting on
        // permission given under the old one.
        let grant: ConsentGrant
        switch consent.request(lease: lease,
                               harness: request.harness,
                               installedHarnesses: settings.installedHarnesses.count,
                               now: now()) {
        case .granted(let granted):
            grant = granted
        case .awaiting(let prompt):
            switch await ask(prompt) {
            case .accepted(let granted, _):
                grant = granted
            case .denied:
                return .failure(.denied, loc("The user declined."))
            case .timedOut, .unrecognized, .ignored:
                return .failure(.timeout, loc("Nobody answered."))
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
            } catch {
                return .failure(.unavailable, error.localizedDescription)
            }
        case .start, .poll, .stop:
            return .failure(.badRequest,
                            loc("This version of Aloud only supports a single blocking listen."))
        }
    }

    // MARK: lease checks

    private func validate(_ lease: String) -> BridgeResponse? {
        switch leases.validate(lease: lease, now: now()) {
        case .success:
            return nil
        case .failure(.disabled):
            return .failure(.disabled, loc("Voice is turned off in Aloud."))
        case .failure(.notHolder):
            // Expired, reaped, or never theirs. Distinct from `queued`: there
            // is nothing to wait for, the session is simply over.
            return .failure(.notHolder, loc("That session has ended — claim again."))
        }
    }

    // MARK: user override

    // The menu bar pulling the plug. Ends the session and answers any prompt
    // still parked on it, so a waiting agent gets a refusal instead of hanging
    // until its own timeout.
    func forceRelease() {
        if let lease = leases.holder?.id {
            resolve(lease, .denied(preConsentAudio: .discarded))
            consent.endLease(lease)
        }
        leases.forceRelease(now: now())
    }
}
