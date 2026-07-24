import Foundation

// On-device rewrite engine behind the "Concise" clean-up level. The system
// language model does the rewriting; nothing ever leaves the Mac and there is
// nothing to download — on machines without it the feature simply isn't shown
// and the deterministic clean-up levels carry on unchanged.
//
// Doctrine (measured, not vibes — see eval/enhancement/):
//   - Deterministic TextPolisher runs FIRST; the model only tightens wording.
//   - Commit path only, never the live-preview loop.
//   - Any error, oddity, or timeout falls back to the polished text — a rough
//     transcript beats a lost one.
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

    static func validate(_ output: String, original: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("```") else { return nil }
        let lowered = trimmed.lowercased()
        guard !refusalPrefixes.contains(where: { lowered.hasPrefix($0) }) else { return nil }
        // Role-flip net: the speaker asked the reader for something, and the
        // rewrite answered instead ("can you send me…" → "Sure, I'll send
        // it"). Structural, not semantic — narrow on purpose.
        let asked = ["can you", "could you", "will you", "would you"]
        let originalLowered = original.lowercased()
        if asked.contains(where: originalLowered.contains),
           !asked.contains(where: lowered.contains),
           ["sure", "okay", "ok,", "i'll ", "i will "].contains(where: lowered.hasPrefix) {
            return nil
        }
        // A rewrite should be at most modestly longer than what was said —
        // big growth means the model composed instead of cleaned.
        guard trimmed.count <= max(original.count * 2, original.count + 80) else { return nil }
        return trimmed
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
