import Foundation

// What a session calls itself.
//
// The harness id says which tool is talking. It cannot say which *session*:
// two windows of Claude Code are both "claude-code", and the moment there are
// two of them is exactly the moment the user needs to tell them apart — to
// know which one is asking, and to end the right one. So every session names
// what it is doing, in the caller's own words, and that name is what appears
// on the pill, in the spoken prompt, and in the menu bar's list.
//
// Short by rule rather than by hope. This lands in a spoken sentence ("Let
// fixing tests listen?") and in a button in a 360-point menu, and neither
// survives a sentence-length name. Two words is the budget.
//
// A label, exactly like the harness id: anything may claim any name, it can
// change mid-session, and nothing is granted on the strength of it.
enum SessionName {
    static let maxWords = 2
    // Enough for two real words; past this it is a sentence wearing a
    // disguise, and it will be truncated on screen rather than read.
    static let maxCharacters = 28

    enum Invalid: Error, Equatable {
        case missing
        case tooManyWords
        case tooLong

        // Written for an agent to act on, not for a user to read: say what is
        // wrong and what would be right, so the retry succeeds.
        var message: String {
            switch self {
            case .missing:
                return "Every session needs a --name saying what it is doing, "
                     + "at most \(SessionName.maxWords) words: --name \"fixing tests\"."
            case .tooManyWords:
                return "--name must be at most \(SessionName.maxWords) words — "
                     + "say what you are doing, not how: --name \"fixing tests\"."
            case .tooLong:
                return "--name must be at most \(SessionName.maxCharacters) characters."
            }
        }
    }

    // Collapses whitespace so "  fixing   tests " and "fixing tests" are the
    // same name, and so word counting cannot be fooled by spacing.
    static func normalize(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    static func validate(_ raw: String?) -> Result<String, Invalid> {
        let name = normalize(raw ?? "")
        guard !name.isEmpty else { return .failure(.missing) }
        // Words before length: a sentence is over both budgets, and "two words
        // at most" is the rule an agent can act on. Being told it is 34
        // characters teaches it to abbreviate rather than to say less.
        guard name.split(separator: " ").count <= maxWords else {
            return .failure(.tooManyWords)
        }
        guard name.count <= maxCharacters else { return .failure(.tooLong) }
        return .success(name)
    }
}
