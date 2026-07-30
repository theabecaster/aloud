import Foundation

// Learns from corrections made while the dictation is still running — the
// user watches the preview land, fixes a word, and keeps talking. The commit
// can't see those edits by diffing the screen (it surrendered the screen the
// moment the user touched it), but every keystroke of the session passed
// through the event stream, Aloud's own included.
//
// So: two EditTracker replays over the same session, both starting from an
// empty field. One consumes only Aloud's synthetic events — what the field
// would hold had the user never intervened. The other consumes everything —
// what the field actually holds. The difference between the two at commit is
// precisely the user's contribution, with Aloud's own typing cancelled out.
//
// When the user's cursor goes unknowable (a click), their tracker degrades to
// burst collection as usual; synthetic typing arriving mid-burst acts as a
// separator rather than content, so Aloud's own words can never pollute a
// burst that gets fuzzy-matched later.
struct SessionEditAudit {

    // What the field actually holds: Aloud's stream and the user's, in order.
    private var actual = EditTracker(injected: "")
    // What it would hold if the user had never touched it.
    private var aloudAlone = EditTracker(injected: "")

    private(set) var userTouched = false

    struct Conclusion {
        let candidates: [CorrectionDiff.Candidate]
        // The field's final text when it is exactly known; nil once a click
        // made it unknowable. Callers arming a post-commit tracker need the
        // real screen contents, not the canonical text that never landed.
        let screenText: String?
    }

    mutating func consumeSynthetic(_ input: EditTracker.Input) {
        aloudAlone.consume(input)
        // Aloud typing at the (unknowable) cursor mid-burst: position moved,
        // burst over — but the synthetic characters are not the user's.
        if actual.phase == .approximate {
            switch input {
            case .text, .backspace, .forwardDelete:
                actual.consume(.nav)
            default:
                actual.consume(input)
            }
        } else {
            actual.consume(input)
        }
    }

    mutating func consumeUser(_ input: EditTracker.Input) {
        userTouched = true
        actual.consume(input)
    }

    // Settle the session: what did the user change, relative to what Aloud
    // alone would have produced?
    func conclude() -> Conclusion {
        guard userTouched else {
            return Conclusion(candidates: [], screenText: nil)
        }
        let aloud = aloudAlone.outcome.exactText
        let out = actual.outcome
        var candidates: [CorrectionDiff.Candidate] = []
        if out.exactText != aloud {
            candidates += CorrectionLearner.passiveCandidates(original: aloud,
                                                              corrected: out.exactText)
        }
        for burst in out.bursts {
            guard let guess = CorrectionGuess.candidate(injected: aloud, typed: burst),
                  !candidates.contains(where: {
                      $0.from.caseInsensitiveCompare(guess.from) == .orderedSame
                  }) else { continue }
            candidates.append(guess)
        }
        return Conclusion(candidates: candidates,
                          screenText: actual.phase == .exact ? out.exactText : nil)
    }
}
