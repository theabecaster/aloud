import Foundation

// Whether an agent may turn on the microphone, and how the user says so.
//
// A local process asking for the mic is the sharp end of the whole bridge
// (docs/agent-voice-bridge.md §7.1). Three modes, set by the two switches in
// Settings → Agent Speak (see AgentConsentMode):
//
//   open            — allowed immediately, no prompt.
//   confirmOnScreen — the pill opens pending, with accept / deny controls.
//   confirmByVoice  — the question is asked out loud ("Let an agent listen?
//                     Yes or no"), the microphone opens when it finishes,
//                     and nothing reaches the agent until the user agrees.
//
// Two invariants are load-bearing and are modelled in the types rather than
// left to the caller's discipline:
//
//   1. Consent is granted once per *lease*, not per listen. A session claims a
//      lease, the user consents once, and every listen inside that lease is
//      free until release. Consent never survives the lease it was given for.
//   2. Silence is never consent. No answer is `timedOut`, which is a different
//      outcome from `denied` — a muted Mac produces timeouts forever, and an
//      agent that keeps retrying those is worse than one that gives up and asks
//      in text (§7.1b: `denied` may be asked again, `timeout` should not be).
//
// Deliberately pure, like LeaseManager: the clock is a parameter, there are no
// timers and nothing is async, so every expiry and every keyword rule is
// testable instantly. Nothing in here touches audio, the GUI or the socket.

// MARK: - modes and configuration

// The three modes live in AgentConsentMode (Settings owns that type); this is
// the one thing the policy needs to know about them.
extension AgentConsentMode {
    // Whether the microphone is open before the user has agreed to share it.
    // Only confirm-by-voice does this, and only to hear the answer.
    var capturesBeforeConsent: Bool { self == .confirmByVoice }
}

struct ConsentConfig: Equatable {
    // How long the user has to answer. Silence past this is a timeout, never a
    // grant. Short on purpose: the prompt interrupts whatever the user is doing
    // and a stale question answered a minute later is worse than no question.
    var timeout: TimeInterval = 20

    // Longest utterance that can *be* an answer, in words. The consent word has
    // to be the whole reply or the start of a short one — see ConsentKeywords
    // for why a "yes" buried in a sentence must not count.
    var maxAnswerWords: Int = 4

    static let `default` = ConsentConfig()

    // The consent timeout must sit strictly under the harness's own command
    // timeout (§7.1c/§7.3), or the user accepts into a command that already
    // gave up: the mic opens, the agent is gone, and nobody is left to close
    // it. This is the shortest command budget across the harnesses we install,
    // kept here so the invariant is checkable rather than folklore.
    static let harnessCommandTimeout: TimeInterval = 120
    // Room for the round trip either side of the wait — socket, model warm-up,
    // the spoken prompt itself.
    static let harnessTimeoutMargin: TimeInterval = 10

    var fitsHarnessCommandTimeout: Bool {
        timeout > 0 && timeout <= ConsentConfig.harnessCommandTimeout - ConsentConfig.harnessTimeoutMargin
    }
}

// MARK: - what the caller may do with the audio

// The disposition of audio captured *before* consent existed. There are two
// cases and neither of them is "hand it to the agent" — that absence is the
// point. Mode 3 records the user in order to hear one word from them; anything
// else would mean we recorded them first and asked afterwards (§7.1 edge 1).
enum PreConsentAudio: Equatable {
    case neverCaptured   // modes 1 and 2: the mic never opened before consent
    case discarded       // mode 3: captured only to hear the answer, now destroyed
}

// What the mic should be doing while the prompt is up.
enum PreConsentCapture: Equatable {
    case none            // do not open the microphone yet
    case forConsentOnly  // open it, but the samples exist only to be classified
}

// Permission to stream. `streamStartsAt` is the instant of accept: no sample
// captured before it may ever reach the agent, which is why the grant carries
// the boundary instead of leaving the caller to remember it.
struct ConsentGrant: Equatable {
    let lease: String
    let streamStartsAt: Date
}

// A decision the user has not made yet. Nothing reaches the agent while one of
// these is outstanding.
struct ConsentPrompt: Equatable {
    let lease: String
    let harness: String
    // What the session is doing — what the user reads and hears, instead of
    // "an agent" or the tool's name.
    let name: String
    let mode: AgentConsentMode
    // Spoken in mode 3, shown on the pill in mode 2 — same wording, same
    // one-vs-many naming rule (§7.1c).
    let text: String
    let capture: PreConsentCapture
    let askedAt: Date
    let deadline: Date
}

enum ConsentRequest: Equatable {
    case granted(ConsentGrant)     // proceed now
    case awaiting(ConsentPrompt)   // ask, and send the agent nothing until it resolves
}

enum ConsentResolution: Equatable {
    case accepted(ConsentGrant, preConsentAudio: PreConsentAudio)
    case denied(preConsentAudio: PreConsentAudio)
    case timedOut(preConsentAudio: PreConsentAudio)
    // Heard something that is not an answer. Still pending, still on the same
    // clock — re-prompt, never assume.
    case unrecognized(ConsentPrompt)
    // Nothing is waiting on this channel: a duplicate answer, an answer for a
    // lease that already resolved, or a spoken answer in a mode that isn't
    // listening for one.
    case ignored
}

// MARK: - the policy

final class ConsentPolicy {
    var mode: AgentConsentMode {
        didSet {
            // Tightening the policy has to apply now, not at the next lease.
            // A user who switches to confirm-by-voice while an agent holds a
            // grant expects to be asked, so grants and any open prompt are
            // dropped. Cheap: the agent is simply asked once more.
            guard mode != oldValue else { return }
            reset()
        }
    }
    var language: ConsentLanguage
    private(set) var config: ConsentConfig
    private(set) var pending: ConsentPrompt?

    // Lease id → when the user consented. Keyed by lease and nothing else: a
    // different lease is a different session and must ask again, even from the
    // same harness and the same pid.
    private(set) var grants: [String: Date] = [:]

    init(mode: AgentConsentMode = .confirmOnScreen,
         config: ConsentConfig = .default,
         language: ConsentLanguage = .current) {
        self.mode = mode
        self.config = config
        self.language = language
    }

    // MARK: asking

    // An agent wants to listen. `installedHarnesses` is the number of harnesses
    // installed on this Mac, passed in rather than discovered here — it only
    // decides whether the prompt names the caller (§7.1c).
    //
    // Idempotent, like LeaseManager.claim: asking again while the same lease's
    // prompt is up returns that same prompt rather than restarting its clock,
    // so a retrying agent cannot keep the user's deadline alive forever.
    func request(lease: String,
                 harness: String,
                 name: String,
                 installedHarnesses: Int,
                 now: Date) -> ConsentRequest {
        expire(now: now)

        // Consent already given for this session — every later listen in it is
        // free. The stream still starts now; nothing older is in scope.
        if grants[lease] != nil {
            return .granted(ConsentGrant(lease: lease, streamStartsAt: now))
        }

        if mode == .open {
            return .granted(ConsentGrant(lease: lease, streamStartsAt: now))
        }

        if let pending, pending.lease == lease {
            return .awaiting(pending)
        }

        // A prompt for a different lease is abandoned rather than answered:
        // whoever it was asked for no longer holds the microphone. Its audio
        // goes the same way as a decline's.
        pending = nil

        let prompt = ConsentPrompt(
            lease: lease,
            harness: harness,
            name: name,
            mode: mode,
            text: ConsentPolicy.promptText(sessionName: name),
            capture: mode.capturesBeforeConsent ? .forConsentOnly : .none,
            askedAt: now,
            deadline: now.addingTimeInterval(config.timeout))
        pending = prompt
        return .awaiting(prompt)
    }

    // MARK: answering

    // The user clicked accept, or pressed the hotkey. Also accepted in mode 3 —
    // someone who reaches for the pill mid-prompt has clearly decided.
    func accept(lease: String, now: Date) -> ConsentResolution {
        guard let prompt = live(lease: lease, now: now) else { return .ignored }
        return resolveAccepted(prompt, now: now)
    }

    // The user clicked deny, or pressed Esc. `denied` is a decision about this
    // request; the agent may reasonably ask again later in the session.
    func decline(lease: String, now: Date) -> ConsentResolution {
        guard let prompt = live(lease: lease, now: now) else { return .ignored }
        pending = nil
        return .denied(preConsentAudio: audioDisposition(for: prompt))
    }

    // Something was heard while a mode 3 prompt was up. Only mode 3 listens for
    // an answer — in mode 2 the microphone is not even open, so anything
    // arriving on this channel is not a decision.
    func heard(_ utterance: String, lease: String, now: Date) -> ConsentResolution {
        guard let prompt = live(lease: lease, now: now) else { return .ignored }
        guard prompt.mode == .confirmByVoice else { return .ignored }

        switch ConsentKeywords.classify(utterance, language: language, maxAnswerWords: config.maxAnswerWords) {
        case .accept:
            return resolveAccepted(prompt, now: now)
        case .decline:
            pending = nil
            return .denied(preConsentAudio: audioDisposition(for: prompt))
        case .unrecognized:
            // Ambiguous or unrelated speech is never consent, and it does not
            // buy more time either — the deadline is unchanged, so a room full
            // of chatter still ends in a timeout.
            return .unrecognized(prompt)
        }
    }

    // Nobody answered. Call this on any clock tick the caller already has;
    // it resolves at most once per prompt and returns nil while one is still
    // live. Silence resolves to `timedOut`, never to `denied` — the agent has
    // to be able to tell "the user said no" from "nobody was there".
    @discardableResult
    func check(now: Date) -> ConsentResolution? {
        guard let prompt = pending, now >= prompt.deadline else { return nil }
        pending = nil
        return .timedOut(preConsentAudio: audioDisposition(for: prompt))
    }

    // MARK: lease lifetime

    func isGranted(lease: String) -> Bool { grants[lease] != nil }

    // The lease ended (released, reaped, force-released). Consent dies with it:
    // the next session starts from nothing, whoever claims it.
    func endLease(_ lease: String) {
        grants[lease] = nil
        if pending?.lease == lease { pending = nil }
    }

    // The master switch went off, or the mode changed under us.
    func reset() {
        grants.removeAll()
        pending = nil
    }

    // MARK: prompt wording (§7.1c)

    // The prompt says what the session is doing, because that is the thing the
    // user is being asked to allow. Naming the tool answered a question nobody
    // had — with one harness installed "an agent" was noise, and with two
    // windows of the same one "Claude Code" could not tell them apart. "Let
    // fixing tests listen?" is short enough to say and specific enough to
    // answer.
    //
    // It asks for "yes or no" rather than "accept or decline" because those are
    // the words the recognizer can actually hear. Measured on the shipping
    // engine, a spoken "accept" came back as "Except for the same thing" —
    // near-homophone, one isolated word, no context for the model to lean on,
    // so its language prior wins and pads it into a sentence. The same voice
    // saying "yes" transcribed as "Yes." every time. Accept and decline stay in
    // the keyword set for anyone who says them; the fix is to stop *asking* for
    // a word we cannot hear, rather than to loosen what counts as consent.
    // The session's name is a task ("fixing tests"), so on its own the sentence
    // reads as though the task is doing the listening. The word *agent* after it
    // says what the name belongs to: "Let fixing tests agent listen?"
    static func promptText(sessionName: String) -> String {
        loc("Let %@ agent listen? Yes or no", sessionName)
    }

    // "claude-code" → "Claude Code". A label for the user's benefit, never
    // authentication (§7.1c) — anything may pass any harness id.
    static func displayName(forHarness harness: String) -> String {
        let words = harness.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
        guard !words.isEmpty else { return harness }
        return words.map { word -> String in
            let lower = word.lowercased()
            if lower == "cli" || lower == "ai" || lower == "ide" { return lower.uppercased() }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }

    // MARK: internals

    // The live prompt for this lease, after expiring a stale one. Expiry is
    // checked on the way into every answer so a late click cannot land on a
    // prompt whose clock ran out.
    private func live(lease: String, now: Date) -> ConsentPrompt? {
        expire(now: now)
        guard let prompt = pending, prompt.lease == lease else { return nil }
        return prompt
    }

    private func resolveAccepted(_ prompt: ConsentPrompt, now: Date) -> ConsentResolution {
        pending = nil
        grants[prompt.lease] = now
        // The stream starts at the accept, and the audio that carried the
        // accept is destroyed with everything before it: capturing early exists
        // only to hear the consent word, never to give the agent a head start.
        return .accepted(ConsentGrant(lease: prompt.lease, streamStartsAt: now),
                         preConsentAudio: audioDisposition(for: prompt))
    }

    private func audioDisposition(for prompt: ConsentPrompt) -> PreConsentAudio {
        prompt.capture == .forConsentOnly ? .discarded : .neverCaptured
    }

    // Drops a prompt whose deadline has passed. The outcome is reported through
    // `check(now:)`; this is the silent half, so that a request arriving after
    // a timeout starts a fresh question rather than inheriting a dead one.
    private func expire(now: Date) {
        guard let deadline = pending?.deadline, now >= deadline else { return }
        pending = nil
    }
}

// MARK: - keywords

enum ConsentAnswer: Equatable {
    case accept
    case decline
    case unrecognized
}

// The five languages Aloud ships (Sources/Aloud/Resources/*.lproj).
enum ConsentLanguage: String, CaseIterable, Equatable {
    case en
    case de
    case es
    case fr
    case ptBR = "pt-BR"

    static func matching(_ identifier: String) -> ConsentLanguage {
        let lower = identifier.lowercased().replacingOccurrences(of: "_", with: "-")
        if lower.hasPrefix("pt") { return .ptBR }   // pt-PT answers the same words
        for language in ConsentLanguage.allCases where lower.hasPrefix(language.rawValue.lowercased()) {
            return language
        }
        return .en
    }

    static var current: ConsentLanguage {
        matching(Locale.preferredLanguages.first ?? Locale.current.identifier)
    }
}

// Deciding whether the user just said yes.
//
// THE MATCHING RULE, and why it is this one:
//
//   A consent word counts only when it is the *whole* normalized utterance, or
//   the leading token(s) of a short one (≤ maxAnswerWords, 4 by default).
//   Anywhere else in the sentence it is ignored.
//
// The mic is open before consent exists, so whatever the room is doing lands
// here. "Yes, I'll pick up milk on the way home" must not turn a phone call
// into permission — hence the length ceiling. Answers to a direct question are
// short ("yes", "yes please", "go ahead"), and they lead with the word, so the
// rule keeps everything a real answer looks like and drops the rest. An
// utterance containing both an accept and a decline word is ambiguous and
// resolves to `unrecognized`: re-prompt, never guess.
//
// Anything unrecognized stays pending until the deadline, so the failure mode
// of a too-strict rule is a timeout — which the agent is told about honestly —
// while the failure mode of a loose one is a microphone the user never agreed
// to open. The asymmetry is the whole reason for the ceiling.
//
// Matching runs against the app's language plus English: English "ok" and "no"
// are used in all five, and none of the English keywords collide with a word
// meaning the opposite in another shipped language.
enum ConsentKeywords {
    // Case- and diacritic-insensitive, punctuation stripped, whitespace
    // collapsed: "Sí, claro!" → "si claro", "J'accepte." → "jaccepte".
    static func normalize(_ text: String) -> String {
        // Apostrophes are removed rather than split on, so French elision stays
        // one word ("j'accepte" → "jaccepte"); every other separator becomes a
        // space ("vas-y" → "vas y").
        let deelided = text.filter { !"'’‘`´".contains($0) }
        let folded = deelided.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                      locale: Locale(identifier: "en_US_POSIX"))
        let letters = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(letters).split(separator: " ").joined(separator: " ")
    }

    static func classify(_ utterance: String,
                         language: ConsentLanguage,
                         maxAnswerWords: Int = ConsentConfig.default.maxAnswerWords) -> ConsentAnswer {
        let words = normalize(utterance).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return .unrecognized }

        let accepting = accept(language)
        let declining = decline(language)

        // "yes no", "no wait yes" — a short reply carrying both words is
        // someone thinking out loud, not a decision. Checked across every token
        // rather than just the leading one, because the leading-token rule
        // below would otherwise let whichever word came first win.
        if words.count <= maxAnswerWords,
           words.contains(where: { accepting.contains($0) }),
           words.contains(where: { declining.contains($0) }) {
            return .unrecognized
        }

        let accepted = matches(words, phrases: accepting, maxAnswerWords: maxAnswerWords)
        let declined = matches(words, phrases: declining, maxAnswerWords: maxAnswerWords)
        if accepted && declined { return .unrecognized }
        if accepted { return .accept }
        if declined { return .decline }
        return .unrecognized
    }

    private static func matches(_ words: [String], phrases: Set<String>, maxAnswerWords: Int) -> Bool {
        if phrases.contains(words.joined(separator: " ")) { return true }
        // Past the ceiling this is a sentence, not an answer — a keyword inside
        // it is someone talking, not someone consenting.
        guard words.count <= maxAnswerWords else { return false }
        for length in 1...min(longestPhrase, words.count)
        where phrases.contains(words.prefix(length).joined(separator: " ")) {
            return true
        }
        return false
    }

    // The longest multi-word keyword we ship ("de acuerdo", "go ahead", …).
    private static let longestPhrase = 3

    static func accept(_ language: ConsentLanguage) -> Set<String> {
        english.accept.union(table(language).accept)
    }

    static func decline(_ language: ConsentLanguage) -> Set<String> {
        english.decline.union(table(language).decline)
    }

    private struct KeywordSet {
        let accept: Set<String>
        let decline: Set<String>
    }

    private static func table(_ language: ConsentLanguage) -> KeywordSet {
        switch language {
        case .en: return english
        case .de: return german
        case .es: return spanish
        case .fr: return french
        case .ptBR: return portuguese
        }
    }

    // Generous but not reckless: the words a person actually says to a machine
    // that just asked them a yes/no question. No bare "well", "sure thing" or
    // other phrases that appear mid-conversation as filler.
    private static let english = KeywordSet(
        accept: ["accept", "accepted", "yes", "yeah", "yep", "yup", "ok", "okay",
                 "sure", "go ahead", "goahead", "do it", "listen", "granted", "allow"],
        decline: ["decline", "declined", "no", "nope", "nah", "cancel", "stop",
                  "deny", "denied", "dont", "do not", "not now", "no thanks"])

    private static let german = KeywordSet(
        accept: ["ja", "jawohl", "akzeptieren", "annehmen", "einverstanden",
                 "klar", "gerne", "zustimmen", "mach", "leg los", "los"],
        decline: ["nein", "ne", "nee", "ablehnen", "abbrechen", "stopp",
                  "nicht", "abgelehnt", "kein"])

    private static let spanish = KeywordSet(
        accept: ["si", "acepto", "aceptar", "vale", "claro", "adelante", "dale",
                 "de acuerdo"],
        decline: ["no", "rechazar", "rechazo", "cancelar", "cancela", "detener",
                  "para nada", "negativo"])

    private static let french = KeywordSet(
        accept: ["oui", "ouais", "accepte", "accepter", "jaccepte", "daccord",
                 "vas y", "allez y", "bien sur"],
        decline: ["non", "refuse", "refuser", "je refuse", "annuler", "annule",
                  "arrete", "arreter", "pas maintenant"])

    private static let portuguese = KeywordSet(
        accept: ["sim", "aceito", "aceitar", "aceite", "claro", "pode",
                 "manda", "beleza", "ta bom", "tudo bem"],
        decline: ["nao", "recuso", "recusar", "cancelar", "cancela", "pare",
                  "parar", "agora nao", "negativo"])
}
