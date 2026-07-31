import XCTest
@testable import Aloud

// Consent is the thing standing between a local process and a live microphone,
// so its edges are pinned here rather than trusted: silence must never read as
// yes, a decline must never read as a timeout (or the agent retries forever),
// consent given for one session must never leak into the next, and the audio
// captured *before* the user agreed must never survive any outcome.
final class ConsentPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func policy(_ mode: AgentConsentMode,
                        timeout: TimeInterval = 20,
                        language: ConsentLanguage = .en) -> ConsentPolicy {
        var config = ConsentConfig.default
        config.timeout = timeout
        // The language is injected everywhere: the process locale belongs to
        // whoever runs the test host, and every shipped language has to be
        // verifiable in a single run.
        return ConsentPolicy(mode: mode, config: config, language: language)
    }

    // MARK: mode 1 — open

    // Open mode is the whole point of opting into it: no prompt, no pending
    // state, and the stream starts immediately.
    func testOpenModeGrantsWithoutAsking() {
        let p = policy(.open)
        guard case .granted(let grant) = p.request(lease: "L1", harness: "claude-code",
                                                   installedHarnesses: 1, now: t0) else {
            return XCTFail("open mode must not prompt")
        }
        XCTAssertEqual(grant.lease, "L1")
        XCTAssertEqual(grant.streamStartsAt, t0)
        XCTAssertNil(p.pending, "nothing should be waiting on the user")
    }

    // MARK: mode 2 — confirm on screen

    func testConfirmOnScreenWaitsForTheClickAndOnlyThenGrants() {
        let p = policy(.confirmOnScreen)
        guard case .awaiting(let prompt) = p.request(lease: "L1", harness: "claude-code",
                                                     installedHarnesses: 1, now: t0) else {
            return XCTFail("mode 2 must hold the request until the user answers")
        }
        // The microphone stays shut until the user says so — mode 2 has a
        // screen to ask on, so there is no reason to open it early.
        XCTAssertEqual(prompt.capture, .none)
        XCTAssertEqual(prompt.deadline, t0.addingTimeInterval(20))

        let at = t0.addingTimeInterval(3)
        guard case .accepted(let grant, let audio) = p.accept(lease: "L1", now: at) else {
            return XCTFail("clicking accept must grant")
        }
        XCTAssertEqual(grant.streamStartsAt, at, "the stream starts at the accept, not at the request")
        XCTAssertEqual(audio, .neverCaptured)
        XCTAssertNil(p.pending)
    }

    // Asking again while the prompt is up must not restart the user's clock —
    // a retrying agent could otherwise keep a question alive indefinitely.
    func testRepeatedRequestReturnsTheSamePromptWithTheSameDeadline() {
        let p = policy(.confirmOnScreen)
        guard case .awaiting(let first) = p.request(lease: "L1", harness: "claude-code",
                                                    installedHarnesses: 1, now: t0),
              case .awaiting(let again) = p.request(lease: "L1", harness: "claude-code",
                                                    installedHarnesses: 1, now: t0.addingTimeInterval(5)) else {
            return XCTFail("expected the same pending prompt")
        }
        XCTAssertEqual(first, again)
    }

    // MARK: mode 3 — confirm by voice

    func testConfirmByVoiceCapturesForTheAnswerAndGrantsOnTheAcceptWord() {
        let p = policy(.confirmByVoice)
        guard case .awaiting(let prompt) = p.request(lease: "L1", harness: "claude-code",
                                                     installedHarnesses: 1, now: t0) else {
            return XCTFail("mode 3 must hold the request until the user answers")
        }
        // Capture starts with the prompt so the answer is not clipped — and the
        // type says what that audio is for, and only that.
        XCTAssertEqual(prompt.capture, .forConsentOnly)
        XCTAssertTrue(prompt.text.contains("accept"))

        let at = t0.addingTimeInterval(2)
        guard case .accepted(let grant, let audio) = p.heard("yes", lease: "L1", now: at) else {
            return XCTFail("'yes' must be consent")
        }
        XCTAssertEqual(grant.streamStartsAt, at)
        // Even on accept the pre-consent audio is destroyed: the agent's stream
        // begins at the accept, it does not inherit what we recorded to hear it.
        XCTAssertEqual(audio, .discarded)
    }

    // A spoken answer is only a decision in the mode that asked for one. In
    // mode 2 the mic is not even open, so speech arriving here is not consent.
    func testSpokenAnswerIsIgnoredInConfirmOnScreenMode() {
        let p = policy(.confirmOnScreen)
        _ = p.request(lease: "L1", harness: "claude-code", installedHarnesses: 1, now: t0)
        XCTAssertEqual(p.heard("yes", lease: "L1", now: t0.addingTimeInterval(1)), .ignored)
        XCTAssertNotNil(p.pending, "the prompt is still waiting for a real click")
        XCTAssertFalse(p.isGranted(lease: "L1"))
    }

    // MARK: the pre-consent buffer

    // Whatever happens, the audio recorded before consent existed goes away.
    // Three outcomes, one disposition — there is no fourth case in the type
    // that could hand it to the agent.
    func testPreConsentAudioIsDiscardedOnAcceptDeclineAndTimeout() {
        for outcome in ["accept", "decline", "timeout"] {
            let p = policy(.confirmByVoice, timeout: 10)
            _ = p.request(lease: "L1", harness: "claude-code", installedHarnesses: 1, now: t0)

            let resolution: ConsentResolution
            switch outcome {
            case "accept":  resolution = p.heard("accept", lease: "L1", now: t0.addingTimeInterval(1))
            case "decline": resolution = p.heard("no", lease: "L1", now: t0.addingTimeInterval(1))
            default:        resolution = p.check(now: t0.addingTimeInterval(10)) ?? .ignored
            }

            switch resolution {
            case .accepted(_, let audio), .denied(let audio), .timedOut(let audio):
                XCTAssertEqual(audio, .discarded, "\(outcome): pre-consent audio must never survive")
            default:
                XCTFail("\(outcome): expected a resolution, got \(resolution)")
            }
        }
    }

    // MARK: consent is per lease

    // The unit of consent is the session, not the request: an agent that asks a
    // question, hears the answer and asks a follow-up must not re-prompt the
    // user every single time.
    func testConsentPersistsAcrossEveryListenInTheSameLease() {
        let p = policy(.confirmByVoice)
        _ = p.request(lease: "L1", harness: "claude-code", installedHarnesses: 1, now: t0)
        _ = p.heard("go ahead", lease: "L1", now: t0.addingTimeInterval(1))

        for step in 1...10 {
            let now = t0.addingTimeInterval(Double(step) * 30)
            guard case .granted(let grant) = p.request(lease: "L1", harness: "claude-code",
                                                       installedHarnesses: 1, now: now) else {
                return XCTFail("listen \(step) inside a consented lease must not re-prompt")
            }
            XCTAssertEqual(grant.streamStartsAt, now)
        }
        XCTAssertNil(p.pending)
    }

    // …and it dies with the session. A new lease is a new conversation, even
    // from the same harness — otherwise one accept would authorise every future
    // agent run on the machine.
    func testConsentDoesNotCarryOverToADifferentLease() {
        let p = policy(.confirmOnScreen)
        _ = p.request(lease: "L1", harness: "claude-code", installedHarnesses: 1, now: t0)
        _ = p.accept(lease: "L1", now: t0)

        guard case .awaiting = p.request(lease: "L2", harness: "claude-code",
                                         installedHarnesses: 1, now: t0.addingTimeInterval(1)) else {
            return XCTFail("a second lease must ask again")
        }
        XCTAssertFalse(p.isGranted(lease: "L2"))
    }

    func testEndingTheLeaseRevokesConsent() {
        let p = policy(.confirmOnScreen)
        _ = p.request(lease: "L1", harness: "claude-code", installedHarnesses: 1, now: t0)
        _ = p.accept(lease: "L1", now: t0)
        XCTAssertTrue(p.isGranted(lease: "L1"))

        p.endLease("L1")
        XCTAssertFalse(p.isGranted(lease: "L1"))
        guard case .awaiting = p.request(lease: "L1", harness: "claude-code",
                                         installedHarnesses: 1, now: t0.addingTimeInterval(1)) else {
            return XCTFail("a reissued lease id must not inherit the old session's consent")
        }
    }

    // MARK: denied vs timed out

    // The distinction the agent acts on: `denied` is a decision about this
    // request and asking later is fine; `timeout` may be a muted Mac, and an
    // agent that retries those forever is worse than one that gives up.
    func testDeclineIsDeniedAndSilenceIsTimedOut() {
        let declined = policy(.confirmOnScreen)
        _ = declined.request(lease: "L1", harness: "claude-code", installedHarnesses: 1, now: t0)
        XCTAssertEqual(declined.decline(lease: "L1", now: t0.addingTimeInterval(1)),
                       .denied(preConsentAudio: .neverCaptured))
        XCTAssertFalse(declined.isGranted(lease: "L1"))

        let silent = policy(.confirmByVoice, timeout: 15)
        _ = silent.request(lease: "L1", harness: "claude-code", installedHarnesses: 1, now: t0)
        XCTAssertNil(silent.check(now: t0.addingTimeInterval(14)), "still inside the window")
        XCTAssertEqual(silent.check(now: t0.addingTimeInterval(15)),
                       .timedOut(preConsentAudio: .discarded),
                       "no answer is a timeout, never a denial and never a grant")
        XCTAssertFalse(silent.isGranted(lease: "L1"))
    }

    // An accept that lands after the clock ran out must not resurrect the
    // request — by then the harness command has likely gone too.
    func testAcceptingAfterTheDeadlineDoesNothing() {
        let p = policy(.confirmOnScreen, timeout: 5)
        _ = p.request(lease: "L1", harness: "claude-code", installedHarnesses: 1, now: t0)
        XCTAssertEqual(p.accept(lease: "L1", now: t0.addingTimeInterval(6)), .ignored)
        XCTAssertFalse(p.isGranted(lease: "L1"))
    }

    // Babble is not an answer, and it does not buy more time either: a room
    // full of conversation still runs out the clock and times out.
    func testUnrecognisedSpeechKeepsWaitingAndStillTimesOut() {
        let p = policy(.confirmByVoice, timeout: 10)
        _ = p.request(lease: "L1", harness: "claude-code", installedHarnesses: 1, now: t0)

        guard case .unrecognized(let prompt) = p.heard("what was that about the invoice",
                                                       lease: "L1", now: t0.addingTimeInterval(2)) else {
            return XCTFail("unrelated speech must be re-prompted, not accepted")
        }
        XCTAssertEqual(prompt.deadline, t0.addingTimeInterval(10), "the clock must not be extended")
        XCTAssertEqual(p.check(now: t0.addingTimeInterval(10)),
                       .timedOut(preConsentAudio: .discarded))
    }

    // Two answers in one breath is not a decision.
    func testContradictoryAnswerIsNotConsent() {
        XCTAssertEqual(ConsentKeywords.classify("yes no", language: .en), .unrecognized)
    }

    // The timeout has to return before the harness kills the command, or the
    // user accepts into a caller that already gave up (§7.1c/§7.3).
    func testDefaultTimeoutSitsUnderTheHarnessCommandTimeout() {
        XCTAssertTrue(ConsentConfig.default.fitsHarnessCommandTimeout)
        XCTAssertLessThan(ConsentConfig.default.timeout, ConsentConfig.harnessCommandTimeout)
        var reckless = ConsentConfig.default
        reckless.timeout = ConsentConfig.harnessCommandTimeout
        XCTAssertFalse(reckless.fitsHarnessCommandTimeout)
    }

    // MARK: keywords

    // Every shipped language needs both words, because the prompt is spoken in
    // the user's language and an unrecognised answer is a timeout — a user who
    // says "ja" and gets silence has no way to know what went wrong.
    func testAcceptAndDeclineAreRecognisedInEveryShippedLanguage() {
        let cases: [(ConsentLanguage, [String], [String])] = [
            (.en, ["accept", "yes", "yeah", "OK!", "go ahead", "sure"],
                  ["decline", "no", "nope", "cancel", "stop", "no thanks"]),
            (.de, ["ja", "akzeptieren", "einverstanden", "klar", "gerne"],
                  ["nein", "ablehnen", "abbrechen", "nicht", "nee"]),
            (.es, ["sí", "acepto", "vale", "claro", "adelante", "de acuerdo"],
                  ["no", "rechazar", "cancelar", "cancela", "negativo"]),
            (.fr, ["oui", "j'accepte", "d'accord", "vas-y", "bien sûr"],
                  ["non", "refuse", "annuler", "arrête", "pas maintenant"]),
            (.ptBR, ["sim", "aceito", "claro", "beleza", "tá bom"],
                    ["não", "recuso", "cancelar", "pare", "agora não"]),
        ]
        for (language, accepts, declines) in cases {
            for word in accepts {
                XCTAssertEqual(ConsentKeywords.classify(word, language: language), .accept,
                               "\(language.rawValue): '\(word)' should be consent")
            }
            for word in declines {
                XCTAssertEqual(ConsentKeywords.classify(word, language: language), .decline,
                               "\(language.rawValue): '\(word)' should be a refusal")
            }
        }
    }

    // Accents and punctuation come out of a speech model however they come out;
    // matching must not depend on them.
    func testMatchingIgnoresCasePunctuationAndDiacritics() {
        XCTAssertEqual(ConsentKeywords.classify("  Sí, claro!  ", language: .es), .accept)
        XCTAssertEqual(ConsentKeywords.classify("NÃO.", language: .ptBR), .decline)
        XCTAssertEqual(ConsentKeywords.classify("J'accepte…", language: .fr), .accept)
    }

    // The reason for the length ceiling. The mic is open before consent exists
    // in mode 3, so a phone call in the room lands in this classifier — and a
    // "yes" in the middle of an unrelated sentence must never open it.
    func testStrayYesInALongerSentenceIsNotConsent() {
        let overheard = [
            "yes I'll pick up the milk on the way home",
            "well I said yes to the meeting yesterday",
            "no I mean the other file we were looking at earlier",
            "she asked me to accept the invitation for tomorrow evening",
        ]
        for sentence in overheard {
            XCTAssertEqual(ConsentKeywords.classify(sentence, language: .en), .unrecognized,
                           "'\(sentence)' must not decide anything")
        }
        // …while a real answer to a direct question still works, including the
        // polite trimmings people actually use.
        XCTAssertEqual(ConsentKeywords.classify("yes please", language: .en), .accept)
        XCTAssertEqual(ConsentKeywords.classify("go ahead, listen", language: .en), .accept)
        XCTAssertEqual(ConsentKeywords.classify("no thanks", language: .en), .decline)
    }

    // End to end: an overheard sentence inside a live mode 3 prompt leaves the
    // prompt exactly where it was.
    func testOverheardSentenceDoesNotGrantConsentEndToEnd() {
        let p = policy(.confirmByVoice)
        _ = p.request(lease: "L1", harness: "claude-code", installedHarnesses: 1, now: t0)
        guard case .unrecognized = p.heard("yes I'll call them back after lunch",
                                           lease: "L1", now: t0.addingTimeInterval(1)) else {
            return XCTFail("a stray 'yes' must not turn on the microphone")
        }
        XCTAssertFalse(p.isGranted(lease: "L1"))
    }

    // The language of the app decides the keyword set, but English rides along:
    // "ok" and "no" are said everywhere, and a German user answering "ok"
    // deserves to be understood rather than timed out.
    func testEnglishKeywordsWorkAlongsideEveryLanguage() {
        for language in ConsentLanguage.allCases {
            XCTAssertEqual(ConsentKeywords.classify("ok", language: language), .accept, language.rawValue)
            XCTAssertEqual(ConsentKeywords.classify("cancel", language: language), .decline, language.rawValue)
        }
    }

    func testUnknownLocalesFallBackToEnglishRatherThanNothing() {
        XCTAssertEqual(ConsentLanguage.matching("pt_PT"), .ptBR)
        XCTAssertEqual(ConsentLanguage.matching("fr-CA"), .fr)
        XCTAssertEqual(ConsentLanguage.matching("ja-JP"), .en)
    }

    // MARK: prompt wording (§7.1c)

    // With one harness installed, naming it is noise — the user knows who it
    // is. The name only appears when there is genuine ambiguity to resolve.
    func testPromptNamesTheHarnessOnlyWhenSeveralAreInstalled() {
        let alone = ConsentPolicy.promptText(harness: "claude-code", installedHarnesses: 1)
        XCTAssertTrue(alone.lowercased().contains("an agent"), alone)
        XCTAssertFalse(alone.contains("Claude Code"), "one harness: naming it says nothing")

        let crowded = ConsentPolicy.promptText(harness: "claude-code", installedHarnesses: 3)
        XCTAssertTrue(crowded.contains("Claude Code"), crowded)
        XCTAssertFalse(crowded.contains("%@"), "the format argument must be substituted")

        // Both wordings have to say what the user is supposed to do about it.
        for text in [alone, crowded] {
            XCTAssertTrue(text.contains("accept"), text)
            XCTAssertTrue(text.contains("decline"), text)
        }
    }

    // The prompt the pill and the voice both use is built at request time, so
    // the harness count has to reach it through the request.
    func testPendingPromptCarriesTheSameWording() {
        let p = policy(.confirmByVoice)
        guard case .awaiting(let prompt) = p.request(lease: "L1", harness: "codex",
                                                     installedHarnesses: 2, now: t0) else {
            return XCTFail("expected a prompt")
        }
        XCTAssertEqual(prompt.text, ConsentPolicy.promptText(harness: "codex", installedHarnesses: 2))
        XCTAssertTrue(prompt.text.contains("Codex"))
    }

    func testHarnessIdsBecomeReadableNames() {
        XCTAssertEqual(ConsentPolicy.displayName(forHarness: "claude-code"), "Claude Code")
        XCTAssertEqual(ConsentPolicy.displayName(forHarness: "codex"), "Codex")
        XCTAssertEqual(ConsentPolicy.displayName(forHarness: "gemini-cli"), "Gemini CLI")
    }

    // MARK: changing the mode

    // Tightening the policy has to bite immediately. A grant handed out under
    // "open" must not keep the microphone available once the user has switched
    // to a confirm mode.
    func testSwitchingToAStricterModeRevokesOutstandingConsent() {
        let p = policy(.open)
        guard case .granted = p.request(lease: "L1", harness: "claude-code",
                                        installedHarnesses: 1, now: t0) else {
            return XCTFail("expected a grant")
        }
        p.mode = .confirmByVoice
        XCTAssertFalse(p.isGranted(lease: "L1"))
        guard case .awaiting = p.request(lease: "L1", harness: "claude-code",
                                         installedHarnesses: 1, now: t0.addingTimeInterval(1)) else {
            return XCTFail("the new mode must apply to the session already running")
        }
    }
}
