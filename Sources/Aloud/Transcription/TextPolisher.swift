import Foundation

// Deterministic, fully-local post-processing of raw transcripts. No LLM, no
// network: conservative rules that remove noise without ever rewriting meaning.
// The raw transcript is always preserved alongside the polished one (history
// shows both), so nothing is silently lost.
//
// Levels (Settings → Dictation → Clean-up):
//   .off    — raw model output untouched
//   .light  — filler words removed, whitespace/punctuation tidied
//   .standard (default) — light + spoken self-corrections ("scratch that")
//                          + the user's personal replacements
enum PolishLevel: String, Codable, CaseIterable, Identifiable {
    case off, light, standard
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        case .standard: return "Standard"
        }
    }

    var explanation: String {
        switch self {
        case .off: return "Exactly what you said, word for word."
        case .light: return "Removes “um” and “uh”, tidies spacing."
        case .standard: return "Also honors “scratch that” corrections and your replacements."
        }
    }
}

// A user-defined replacement: fix a name the model keeps misspelling, or
// expand a spoken shorthand. Case-insensitive whole-word match.
struct Replacement: Codable, Equatable, Identifiable {
    var id = UUID()
    var pattern: String       // what the model wrote
    var replacement: String   // what it should say
}

struct TextPolisher {
    var level: PolishLevel
    var replacements: [Replacement]

    // Fillers stripped in .light and above. Deliberately short: only sounds
    // that carry no meaning in any context. ("like"/"you know" can be real
    // words — removing them would rewrite meaning, so we never touch them.)
    static let fillers: Set<String> = ["um", "uh", "uhm", "umm", "uhh", "erm", "mhm", "hmm", "mm"]

    // Phrases that mean "delete what I just said". Matched case-insensitively;
    // everything from the start of the current sentence (or the whole text)
    // up to and including the phrase is dropped.
    static let correctionPhrases = ["scratch that", "no wait", "strike that"]

    func polish(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard level != .off, !text.isEmpty else { return text }

        text = Self.stripFillers(text)

        if level == .standard {
            text = Self.applyCorrections(text)
            text = Self.applyReplacements(text, replacements)
        }

        text = Self.tidy(text)
        return text
    }

    // MARK: fillers

    static func stripFillers(_ text: String) -> String {
        // Remove standalone filler tokens along with one adjacent comma the
        // model may have attached ("So, um, yes" → "So, yes").
        let pattern = "(?i)(?:^|(?<=[\\s,.!?]))(?:\(fillers.joined(separator: "|")))(?:[,.]?)(?=\\s|$)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    // MARK: self-corrections

    static func applyCorrections(_ text: String) -> String {
        var result = text
        for phrase in correctionPhrases {
            // Repeat until no occurrence: each correction erases back to the
            // previous sentence boundary before the phrase.
            while let phraseRange = result.range(of: phrase, options: [.caseInsensitive]) {
                let before = result[..<phraseRange.lowerBound]
                // Find the start of the sentence being corrected, keeping the
                // previous sentence's trailing whitespace in the prefix.
                var sentenceStart = before.lastIndex(where: { ".!?\n".contains($0) })
                    .map { result.index(after: $0) } ?? result.startIndex
                while sentenceStart < phraseRange.lowerBound, result[sentenceStart].isWhitespace {
                    sentenceStart = result.index(after: sentenceStart)
                }
                var after = result[phraseRange.upperBound...]
                // Drop punctuation/space immediately after the phrase.
                while let f = after.first, f == "," || f == "." || f == " " { after = after.dropFirst() }
                result = String(result[..<sentenceStart]) + String(after)
            }
        }
        return result
    }

    // MARK: replacements

    static func applyReplacements(_ text: String, _ replacements: [Replacement]) -> String {
        var result = text
        for r in replacements where !r.pattern.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: r.pattern)
            guard let re = try? NSRegularExpression(pattern: "(?i)\\b\(escaped)\\b") else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = re.stringByReplacingMatches(
                in: result, range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: r.replacement))
        }
        return result
    }

    // MARK: tidy

    static func tidy(_ text: String) -> String {
        var t = text
        // Collapse runs of spaces, fix space-before-punctuation, dangling commas.
        t = t.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: " ([,.!?;:])", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "([,.!?;:])[,;]+", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "^[,.;:!? ]+", with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // Capitalize the first letter after sentence-ending punctuation + start.
        t = capitalizeSentences(t)
        return t
    }

    private static func capitalizeSentences(_ text: String) -> String {
        var chars = Array(text)
        var capitalizeNext = true
        for i in chars.indices {
            let c = chars[i]
            if capitalizeNext, c.isLetter {
                chars[i] = Character(c.uppercased())
                capitalizeNext = false
            } else if capitalizeNext, c.isNumber {
                capitalizeNext = false          // "42 dollars" — don't capitalize "dollars"
            } else if ".!?".contains(c) {
                // Sentence end only when followed by whitespace/end — "427.62"
                // must not capitalize what follows.
                let next = chars.index(after: i)
                capitalizeNext = next == chars.endIndex || chars[next].isWhitespace
            }
        }
        return String(chars)
    }
}
