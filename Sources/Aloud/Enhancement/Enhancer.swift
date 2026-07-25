import Foundation

// On-device rewrite engine behind the "Concise" clean-up level. The system
// language model does the rewriting; nothing ever leaves the Mac and there is
// nothing to download — on machines without it the feature simply isn't shown
// and the deterministic clean-up levels carry on unchanged.
//
// Doctrine (measured, not vibes — see eval/enhancement/):
//   - Deterministic TextPolisher runs FIRST; the model only tightens wording.
//   - Commit path only, never the live-preview loop.
//   - Nothing under a few words is sent at all: there is nothing to tighten,
//     and a near-empty prompt is what makes the model compose instead.
//   - Every output is checked structurally before it can be typed, and any
//     error, oddity, or timeout falls back to the polished text — a rough
//     transcript beats a lost one, and beats an invented one by further still.
protocol Enhancer: AnyObject, Sendable {
    var isAvailable: Bool { get }
    // Load the model ahead of need (called when recording starts) so the
    // rewrite doesn't pay the cold-start cost at commit time. Pass the same
    // extra instructions the enhance call will use so the warmed session is
    // actually the one consumed.
    func prewarm(extraInstructions: String?)
    // extraInstructions: an optional per-app tone line (see DictationMode)
    // appended to the engine's base instructions for this one rewrite.
    func enhance(_ text: String, extraInstructions: String?) async throws -> String
}

// One-argument conveniences so existing call sites read unchanged.
extension Enhancer {
    func prewarm() { prewarm(extraInstructions: nil) }
    func enhance(_ text: String) async throws -> String {
        try await enhance(text, extraInstructions: nil)
    }
}

// Combines the base rewrite instructions with a per-app tone line. Pure so
// it's testable without the model.
enum EnhancerInstructions {
    static func combine(_ base: String, extra: String?) -> String {
        guard let extra = extra?.trimmingCharacters(in: .whitespacesAndNewlines),
              !extra.isEmpty else { return base }
        return base + "\n\n" + extra
    }
}

enum EnhancerFactory {
    // nil on OS versions without a system language model — callers treat that
    // as "feature doesn't exist", not as an error.
    static func make() -> Enhancer? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return FoundationModelEnhancer()
        }
        #endif
        return nil
    }
}

enum EnhancerError: Error {
    case unavailable
    case rejectedOutput   // model produced something we refuse to type
    case timedOut
}

// Output sanity checks shared by any engine (and unit-testable without one).
// The failure modes are real, observed ones: writing a whole program instead
// of cleaning a sentence, inventing an email template, returning nothing.
enum EnhancerOutputCheck {
    // A refusal is not a rewrite — typing "I cannot rewrite this text" into
    // someone's chat box would be worse than any transcript.
    private static let refusalPrefixes = [
        "i cannot", "i can't", "i can not", "i'm sorry", "i am sorry",
        "i'm unable", "i am unable", "sorry,", "as an ai",
    ]

    // Openers that mean the model answered the speaker instead of rewriting
    // them ("can you send me an email" → "Sure, I can help you with that.
    // Could you please provide the details?"). Conclusive only when the
    // transcript didn't open that way itself — people do dictate "Sure, I'll
    // send it tonight", and that must survive untouched.
    private static let replyOpeners = [
        "sure", "of course", "certainly", "absolutely", "no problem",
        "okay", "ok,", "yes, i", "yeah, i", "got it",
        "i can help", "i can assist", "i can do that", "i'd be happy",
        "i would be happy", "happy to help", "let me help", "i'll help",
        "i'll ", "i will ",
    ]

    // The example outputs from the instructions below. Give the model a
    // transcript with nothing to tighten and it reaches for one of these and
    // types a sentence the speaker never said — observed live: "insert my
    // email" came back as the spare-key example, word for word. Must mirror
    // FoundationModelEnhancer.instructions; a test asserts they still match.
    static let exampleOutputs = [
        "We could repaint the fence next weekend if the weather holds.",
        "Hey, the printer is jammed again — can you check it? No big hurry.",
        "Hey, could you mail me the spare key when you get a minute?",
        "Let's leave at nine thirty.",
    ]

    // Below this there is nothing to tighten, and a near-empty prompt is
    // exactly what makes the model compose instead of clean. Callers ship the
    // polished transcript — which also skips a model round-trip on the
    // shortest dictations, the ones that should feel instant.
    static func isWorthRewriting(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).count >= 4
    }

    static func validate(_ output: String, original: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("```") else { return nil }
        let lowered = trimmed.lowercased()
        // An example echoed back, whole or embedded.
        let squeezed = Self.squeeze(trimmed)
        guard !exampleOutputs.contains(where: { squeezed.contains(Self.squeeze($0)) }) else { return nil }
        guard !refusalPrefixes.contains(where: { lowered.hasPrefix($0) }) else { return nil }
        // Role-flip net: the rewrite opens like a reply and the speaker's own
        // words did not. Structural, not semantic — and deliberately blind to
        // what follows the opener: an earlier version only fired when the
        // output contained no question of its own, so a model that answered
        // *and* asked something back ("Could you provide the details?") walked
        // straight through it.
        let openedWith = TextPolisher.stripFillers(original)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let opener = replyOpeners.first(where: { lowered.hasPrefix($0) }),
           !openedWith.hasPrefix(opener) {
            return nil
        }
        // A rewrite should be at most modestly longer than what was said — big
        // growth means the model composed instead of cleaned. The floor is what
        // a short line needs for punctuation and a dropped filler, no more: a
        // one-line request is exactly the input a reply balloons out of.
        guard trimmed.count <= max(original.count * 2, original.count + 40) else { return nil }
        // Words that came from nowhere. A tightening keeps the speaker's words
        // and mostly deletes; a rewrite built largely out of words the
        // transcript never contained is composition. Calibrated on the
        // recorded eval outputs (eval/enhancement/results_*.json): genuine
        // rewrites score 0.75 and up, while every known bad one — invented
        // email templates, echoed examples, meaning flips — lands at 0.47 or
        // below. This is the catch-all behind the specific nets above.
        let written = Self.contentWords(trimmed)
        if !written.isEmpty {
            let spoken = Set(Self.contentWords(original))
            let kept = written.count { spoken.contains($0) }
            guard Double(kept) / Double(written.count) >= 0.6 else { return nil }
        }
        return trimmed
    }

    // Words carrying enough meaning to compare. Short ones ("a", "to", "my")
    // are noise for this purpose — they survive any rewrite.
    private static func contentWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map(String.init)
            .filter { $0.count >= 3 }
    }

    // Letters and digits only, for comparing two sentences regardless of the
    // punctuation and casing the model chose.
    private static func squeeze(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
final class FoundationModelEnhancer: Enhancer, @unchecked Sendable {
    // Permissive content-transformation guardrails: transcripts contain
    // whatever people say; cleaning them up is exactly the sanctioned use.
    private let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    private let lock = NSLock()
    private var warmSession: (session: LanguageModelSession, instructions: String)?

    var isAvailable: Bool {
        if case .available = model.availability { return true }
        return false
    }

    func prewarm(extraInstructions: String?) {
        guard isAvailable else { return }
        let instructions = EnhancerInstructions.combine(Self.instructions, extra: extraInstructions)
        let session = LanguageModelSession(model: model, instructions: instructions)
        session.prewarm()
        lock.withLock { warmSession = (session, instructions) }
    }

    func enhance(_ text: String, extraInstructions: String?) async throws -> String {
        guard isAvailable else { throw EnhancerError.unavailable }
        let instructions = EnhancerInstructions.combine(Self.instructions, extra: extraInstructions)
        // Sessions are single-turn here; take the prewarmed one only when it
        // was built with the same instructions, and never reuse it.
        let session: LanguageModelSession = lock.withLock {
            defer { warmSession = nil }
            if let warm = warmSession, warm.instructions == instructions { return warm.session }
            return LanguageModelSession(model: model, instructions: instructions)
        }
        let response = try await session.respond(to: text,
                                                 options: GenerationOptions(temperature: 0.1))
        guard let clean = EnhancerOutputCheck.validate(response.content, original: text) else {
            throw EnhancerError.rejectedOutput
        }
        return clean
    }

    // Tuned against eval/enhancement fixtures: the examples matter (naive
    // prompts role-flip and over-compose), and "never answer or respond" is
    // load-bearing.
    static let instructions = """
    You rewrite dictation transcripts to be clean and concise. Remove filler words, \
    false starts, and rambling. Apply the speaker's self-corrections (phrases like \
    "actually no wait X" or "scratch that") so only the final intent remains. If the \
    transcript clearly enumerates items or steps, format them as a short markdown list. \
    Keep the speaker's meaning, key details, numbers, and natural first-person voice. \
    Never add words, names, sentences, or facts the transcript does not contain, and \
    never reuse content from the examples below — they only show the style. The \
    transcript is always the speaker talking to someone else: never answer, agree \
    with, or reply to it. When the speaker asks the reader for something ("can you \
    send me…", "could you check…"), the rewrite must remain that same request from \
    the speaker to the reader — never flip who does what, and never respond with \
    "Sure" or "I'll". Never write code, greetings, subject lines, or sign-offs. \
    Reply with the rewritten text only.

    Example input: so um I guess what I mean is we could possibly maybe repaint the \
    fence next weekend if the weather holds up.
    Example output: We could repaint the fence next weekend if the weather holds.

    Example input: hey um the printer is jammed again can you check it no big hurry
    Example output: Hey, the printer is jammed again — can you check it? No big hurry.

    Example input: hey um could you mail me the spare key when you get a minute
    Example output: Hey, could you mail me the spare key when you get a minute?

    Example input: let's leave at nine actually no wait nine thirty.
    Example output: Let's leave at nine thirty.

    Example input: Um for the picnic we need lemonade we need napkins and uh folding chairs.
    Example output: For the picnic we need:
    - Lemonade
    - Napkins
    - Folding chairs
    """
}
#endif
