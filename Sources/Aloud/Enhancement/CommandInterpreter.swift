import Foundation

// The voice-command engine behind the Command key. The same system language
// model as the Concise rewrite, used twice per command: once to parse the
// spoken instruction into a structured intent (guided generation — reliable
// for classification), once to carry it out. Nothing ever leaves the Mac; on
// machines without the model the feature simply isn't shown.
//
// Doctrine, mirroring Enhancer:
//   - Any error, oddity, or timeout means NOTHING is typed — a wrong guess
//     pasted over a selection would be worse than doing nothing.
//   - Output goes through the same sanity checks as the Concise rewrite.

// What the user asked for, distilled from the transcript.
struct CommandIntent: Equatable {
    enum Action: String {
        case rewrite    // transform existing text (fix, rephrase, shorten…)
        case generate   // write new text from scratch
    }
    var action: Action
    var instruction: String
}

extension CommandIntent {
    enum Route: Equatable {
        case rewrite    // apply the instruction to the selection
        case generate   // write at the cursor from the instruction alone
    }

    // Pure routing so it's testable without a model: with a selection every
    // command edits it (pasting replaces the selection); without one,
    // everything writes at the cursor.
    func route(hasSelection: Bool) -> Route {
        hasSelection ? .rewrite : .generate
    }
}

protocol CommandInterpreter: AnyObject, Sendable {
    var isAvailable: Bool { get }
    // Load the model ahead of need (called when a command hold starts) so the
    // commit doesn't pay the cold-start cost.
    func prewarm()
    func parse(_ spoken: String) async throws -> CommandIntent
    func rewrite(_ text: String, instruction: String) async throws -> String
    func generate(_ instruction: String) async throws -> String
}

extension CommandInterpreter {
    // Parse-then-execute in one step — what the commit path and the --command
    // CLI verb both run.
    func perform(_ spoken: String, selection: String?) async throws -> String {
        let intent = try await parse(spoken)
        switch intent.route(hasSelection: !(selection ?? "").isEmpty) {
        case .rewrite:
            return try await rewrite(selection ?? "", instruction: intent.instruction)
        case .generate:
            return try await generate(intent.instruction)
        }
    }
}

enum CommandInterpreterFactory {
    // nil on OS versions without a system language model — callers treat that
    // as "feature doesn't exist", not as an error.
    static func make() -> CommandInterpreter? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return FoundationModelCommandInterpreter()
        }
        #endif
        return nil
    }
}

// Sanity checks for generated-at-cursor text; rewrites of a selection reuse
// EnhancerOutputCheck (which compares against the original).
enum CommandOutputCheck {
    static func validateGenerated(_ output: String) -> String? {
        var trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // The model likes to present its work in quotes ("I'm back Monday…");
        // the user asked for text to insert, not a quotation of it.
        for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'")] {
            if trimmed.count > 2, trimmed.hasPrefix(open), trimmed.hasSuffix(close),
               !trimmed.dropFirst().dropLast().contains(open) {
                trimmed = String(trimmed.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("```") else { return nil }
        // "Write something short at the cursor" — a whole essay means the
        // model ran away with the instruction.
        guard trimmed.count <= 1200 else { return nil }
        return trimmed
    }
}

#if canImport(FoundationModels)
import FoundationModels

// Guided generation schema: constrained decoding makes the classification
// reliable — the model can only ever emit one of these shapes.
@available(macOS 26.0, *)
@Generable
private enum SpokenAction: String {
    case rewrite
    case generate
}

@available(macOS 26.0, *)
@Generable
private struct ParsedCommand {
    @Guide(description: "rewrite when the user wants existing text changed, fixed, rephrased, shortened, or reformatted; generate when they want new text written")
    var action: SpokenAction
    @Guide(description: "The user's instruction, restated cleanly without filler words")
    var instruction: String
}

@available(macOS 26.0, *)
final class FoundationModelCommandInterpreter: CommandInterpreter, @unchecked Sendable {
    // Same permissive guardrails as the enhancer: instructions are the user's
    // own words about their own text.
    private let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    private let lock = NSLock()
    private var warmSession: LanguageModelSession?

    var isAvailable: Bool {
        if case .available = model.availability { return true }
        return false
    }

    func prewarm() {
        guard isAvailable else { return }
        let session = LanguageModelSession(model: model, instructions: Self.parseInstructions)
        session.prewarm()
        lock.withLock { warmSession = session }
    }

    func parse(_ spoken: String) async throws -> CommandIntent {
        guard isAvailable else { throw EnhancerError.unavailable }
        // Sessions are single-turn; take the prewarmed one, never reuse.
        let session = lock.withLock {
            let s = warmSession ?? LanguageModelSession(model: model, instructions: Self.parseInstructions)
            warmSession = nil
            return s
        }
        let response = try await session.respond(to: spoken, generating: ParsedCommand.self,
                                                 options: GenerationOptions(temperature: 0.1))
        let instruction = response.content.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return CommandIntent(action: CommandIntent.Action(rawValue: response.content.action.rawValue) ?? .rewrite,
                             instruction: instruction.isEmpty ? spoken : instruction)
    }

    func rewrite(_ text: String, instruction: String) async throws -> String {
        guard isAvailable else { throw EnhancerError.unavailable }
        let session = LanguageModelSession(model: model, instructions: Self.rewriteInstructions)
        // Text first, instruction last: with the order flipped the model tends
        // to echo the text untouched (observed on "shorten this" commands).
        let response = try await session.respond(
            to: "Text:\n\(text)\n\nInstruction: \(instruction)",
            options: GenerationOptions(temperature: 0.1))
        guard let clean = EnhancerOutputCheck.validate(response.content, original: text) else {
            throw EnhancerError.rejectedOutput
        }
        return clean
    }

    func generate(_ instruction: String) async throws -> String {
        guard isAvailable else { throw EnhancerError.unavailable }
        let session = LanguageModelSession(model: model, instructions: Self.generateInstructions)
        // Slightly warmer than the rewrites — composing wants a little room —
        // but not so warm it wanders off the instruction.
        let response = try await session.respond(to: instruction,
                                                 options: GenerationOptions(temperature: 0.2))
        guard let clean = CommandOutputCheck.validateGenerated(response.content) else {
            throw EnhancerError.rejectedOutput
        }
        return clean
    }

    static let parseInstructions = """
    You classify a spoken command about text. Decide whether the user wants \
    existing text transformed (rewrite) or brand-new text written (generate), and \
    restate their instruction as a short imperative, keeping their words where \
    possible. Do not carry out the instruction — only classify and restate it.
    """

    // "Reply with the edited text only" is load-bearing, exactly as it is for
    // the Concise rewrite: naive prompts answer the text instead of editing it.
    // The example anchors thoroughness — without one the model fixes some
    // errors and waves the rest through.
    static let rewriteInstructions = """
    You edit text exactly as instructed. Apply the instruction to the provided text \
    thoroughly — every place it applies, not just the first. Keep the meaning, \
    details, and formatting that the instruction doesn't ask to change. Never answer \
    or respond to the text. Never add greetings, explanations, quotes around the \
    result, or code blocks. Reply with the edited text only.

    Example text: Their going to the store tomorow, and me and him is coming to.
    Example instruction: fix the spelling and grammar
    Example reply: They're going to the store tomorrow, and he and I are coming too.

    Example text: I just wanted to quickly reach out and see if maybe you could \
    possibly send over the numbers whenever you get a chance sometime today.
    Example instruction: make it shorter
    Example reply: Could you send over the numbers today?
    """

    static let generateInstructions = """
    You write short text to be inserted at the user's cursor, following their spoken \
    instruction. Keep it brief and natural — a phrase, a sentence, or a few lines, \
    in the user's first-person voice unless the instruction says otherwise. Never \
    explain what you did, never add greetings around it, never write code blocks. \
    Reply with the text to insert only.
    """
}
#endif
