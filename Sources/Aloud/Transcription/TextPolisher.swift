import Foundation
import NaturalLanguage

// Deterministic, fully-local post-processing of raw transcripts. No LLM, no
// network: conservative rules that remove noise without ever rewriting meaning.
// The raw transcript is always preserved alongside the polished one (history
// shows both), so nothing is silently lost.
//
// Levels (Settings → Dictation → Clean-up):
//   .off    — raw model output untouched
//   .light  — filler words removed, whitespace/punctuation tidied,
//             confidently-recognized names capitalized
//   .standard (default) — light + spoken self-corrections ("scratch that")
//                          + the user's personal replacements
//   .concise — standard first, then an on-device rewrite tightens the wording
//              (only offered on Macs whose system provides the rewrite engine;
//              the exact words are still kept in History)
enum PolishLevel: String, Codable, CaseIterable, Identifiable {
    case off, light, standard, concise
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return loc("Off")
        case .light: return loc("Light")
        case .standard: return loc("Standard")
        case .concise: return loc("Concise")
        }
    }

    // Each one stands on its own: the picker shows a single line at a time, so
    // "also…" told the user nothing unless they'd just read the line above.
    var explanation: String {
        switch self {
        case .off: return loc("Types exactly what you said, word for word.")
        case .light: return loc("Drops “um” and “uh”, fixes spacing, capitalizes names.")
        case .standard: return loc("Light clean-up, plus spoken fixes like “scratch that” and your Vocabulary words.")
        case .concise: return loc("Standard clean-up, then tightens the wording.")
        }
    }

    // The same promise as `explanation`, cut to fit one line beside a control.
    // The menu bar popover has 360pt to work with — the full sentence wraps to
    // three lines there and turns a one-line control into a paragraph.
    var shortSummary: String {
        switch self {
        case .off: return loc("Your exact words")
        case .light: return loc("Drops filler words")
        case .standard: return loc("Fillers, spoken fixes, your words")
        case .concise: return loc("Tightens the wording")
        }
    }

    // The rule-based level that runs before (or instead of) the rewrite.
    var deterministicLevel: PolishLevel {
        self == .concise ? .standard : self
    }

    /// Vocabulary replacements and spoken corrections belong to the Standard
    /// pass, so the two lighter levels never see them. Settings dims the
    /// Vocabulary pane on this.
    var appliesVocabulary: Bool {
        deterministicLevel == .standard
    }

    /// App Rules only ever steer the Concise rewrite — the deterministic
    /// levels write the same way in every app, so a rule has nothing to
    /// change there. Settings dims the App Rules pane on this.
    var appliesAppRules: Bool {
        self == .concise
    }
}

// A user-defined replacement: fix a name the model keeps misspelling, or
// expand a spoken shorthand. Case-insensitive whole-word match.
struct Replacement: Codable, Equatable, Identifiable {
    var id = UUID()
    var pattern: String       // what the model wrote
    var replacement: String   // what it should say
    // Provenance: a rule accepted from a correction suggestion, as opposed to
    // one the user typed by hand. Only learned rules may be retired
    // automatically when the user keeps undoing them — hand-made rules are
    // never touched without the user asking.
    var learned: Bool = false

    init(id: UUID = UUID(), pattern: String, replacement: String, learned: Bool = false) {
        self.id = id
        self.pattern = pattern
        self.replacement = replacement
        self.learned = learned
    }

    // Stored replacement JSON predates `learned` (and users hand-edit these
    // files) — every field decodes defensively so existing rules survive the
    // schema change instead of wiping the whole list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        replacement = try c.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        learned = try c.decodeIfPresent(Bool.self, forKey: .learned) ?? false
    }
}

struct TextPolisher {
    var level: PolishLevel
    var replacements: [Replacement]
    // The Concise rewrite handles "actually no wait" itself — and does it
    // better, because it sees the speaker's whole phrasing. Pre-deleting the
    // span here would hand the model two contradictory sentences with the
    // intent stripped out. Off only for the rewrite's input; the fallback
    // text keeps the deterministic behavior.
    var spokenCorrections = true
    // Spoken numbers are written out as digits (and as times, dates, money,
    // percentages) from .light up — "3 PM" is not a rewrite of "three p.m.",
    // it is how the words are spelled. The rules are language-specific, so the
    // declared dictation languages come along; a language the tables don't
    // cover is left untouched.
    var languages: [String] = ["en"]
    // A preview's last number is still being spoken — "three" may yet become
    // "three thirty". The trailing phrase waits for the next update rather
    // than being typed and rewritten a moment later.
    var finalPass = true
    // Proper-noun capitalization asks the system name tagger about a word in
    // the context of the whole sentence — and its verdict flips as that
    // sentence grows, so during live typing it keeps re-casing words the user
    // is already reading. Previews turn it off; the committed text gets it.
    var capitalizeNames = true

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
            if spokenCorrections { text = Self.applyCorrections(text) }
            text = Self.applyReplacements(text, replacements)
        }

        text = NumberNormalizer.normalize(text, languages: languages, holdTail: !finalPass)

        text = Self.tidy(text)
        guard capitalizeNames else { return text }
        // Words the replacements just produced are the user's exact spelling —
        // the name pass must never second-guess them.
        let protected = level == .standard
            ? Set(replacements.flatMap { $0.replacement.lowercased().split(separator: " ").map(String.init) })
            : []
        text = Self.capitalizeProperNouns(text, skipping: protected)
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

    // MARK: proper nouns

    // The ASR model emits many names lowercase ("tell john i'm in london").
    // Fix the confident ones deterministically with the system's on-device
    // name tagger. Two hurdles make this conservative by construction:
    //
    // 1. The tagger leans heavily on capitalization, so it barely recognizes
    //    lowercase names in place. It runs over a title-cased *probe* of the
    //    text instead — same UTF-16 layout, every lowercase word capitalized —
    //    which restores the shape it expects.
    // 2. Probing that way over-fires on common nouns ("Invoice" reads as an
    //    organization), so a word is only accepted when it is *not* in the
    //    system's English lexicon — names like "gonzalez" aren't, words like
    //    "invoice" are. No lexicon available → the whole pass stands down.
    //
    // Only all-lowercase words are ever touched, and never ones a replacement
    // produced; a miss just leaves the transcript as the model wrote it.
    private static let lexicon = NLEmbedding.wordEmbedding(for: .english)

    static func capitalizeProperNouns(_ text: String, skipping skip: Set<String>) -> String {
        guard let lexicon, !text.isEmpty else { return text }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var tokens: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            tokens.append(range); return true
        }

        // Build the probe back to front so untouched ranges stay valid.
        var probe = text
        var candidates: [Range<String.Index>] = []
        for range in tokens.reversed() {
            let word = String(text[range])
            guard word.count >= 2, word.contains(where: \.isLetter),
                  word == word.lowercased() else { continue }
            let first = word.first!
            let upper = String(first).uppercased()
            // Case changes that alter length (ß → SS) would break the shared
            // layout — leave such words alone.
            guard upper.utf16.count == String(first).utf16.count else { continue }
            let firstRange = range.lowerBound..<text.index(after: range.lowerBound)
            probe.replaceSubrange(sameRange(firstRange, in: probe, as: text), with: upper)
            candidates.append(range)
        }
        guard !candidates.isEmpty else { return text }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = probe
        let nameTags: Set<NLTag> = [.personalName, .placeName, .organizationName]
        var result = text
        for range in candidates {   // still back to front
            let word = String(text[range]).lowercased()
            guard !skip.contains(word), !lexicon.contains(word) else { continue }
            let probeStart = sameRange(range, in: probe, as: text).lowerBound
            guard let tag = tagger.tag(at: probeStart, unit: .word, scheme: .nameType).0,
                  nameTags.contains(tag) else { continue }
            let firstRange = range.lowerBound..<text.index(after: range.lowerBound)
            result.replaceSubrange(firstRange, with: String(text[firstRange]).uppercased())
        }
        return result
    }

    // Probe and text share a UTF-16 layout by construction, so a range in one
    // is the same pair of offsets in the other.
    private static func sameRange(_ range: Range<String.Index>, in probe: String,
                                  as text: String) -> Range<String.Index> {
        let lo = text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound)
        let hi = text.utf16.distance(from: text.utf16.startIndex, to: range.upperBound)
        let plo = probe.utf16.index(probe.utf16.startIndex, offsetBy: lo)
        let phi = probe.utf16.index(probe.utf16.startIndex, offsetBy: hi)
        return (plo.samePosition(in: probe) ?? probe.startIndex)
            ..< (phi.samePosition(in: probe) ?? probe.endIndex)
    }
}
