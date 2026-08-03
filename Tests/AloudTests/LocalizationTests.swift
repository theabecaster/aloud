import XCTest
@testable import Aloud

// The localization tables ship inside the module resource bundle, one
// .lproj per language. Each language's table is loaded directly (not via
// the process locale, which the test host controls) so every language is
// verifiable in a single run.
final class LocalizationTests: XCTestCase {
    private static let languages = ["en", "es", "de", "fr", "pt-BR"]

    // A spread of keys across surfaces: menu bar, status line, settings,
    // onboarding, indicator, uninstall.
    private static let knownKeys = [
        // The spoken consent prompt. Unlike most strings this one is *heard*,
        // and it is what tells someone a decision is being asked of them — a
        // silent fallback to English is a non-English user not knowing to
        // answer at all.
        "Let %@ agent listen? Yes or no",
        // Settings → Agents and the onboarding opt-in. Agent Speak hands local
        // processes the mic and the speakers, so the screens that say so — and
        // the switch that takes it back — cannot fall back to English.
        // "Agent Speak" itself is below, with the pill that announces it: one
        // entry serves the toggle, the sidebar row, and the VoiceOver label.
        "Let coding agents ask you questions out loud.",
        "Lets coding agents ask you a question out loud and hear your answer. Adds an Agent Speak section to Settings.",
        // The bridge-down banner. Straight apostrophe on purpose: it matches
        // the loc() call, and a key that differs by one character resolves to
        // English without anything looking wrong.
        "Agents can’t reach Aloud right now.",
        "Restarting Aloud usually clears this.",
        "The recording indicator always shows while an agent is listening, and nothing leaves this Mac.",
        // The two switches that decide whether an agent is asked before it
        // listens, and the sentence saying what the pair currently costs — a
        // permission decision nobody can read is one made blind.
        "Permission",
        "Ask before listening",
        "Ask out loud",
        "Agents start listening as soon as they ask, without checking with you first.",
        "Aloud asks through your speakers and waits for you to say yes — no need to look at the screen. You’re asked once per session.",
        "The question appears on the recording indicator and waits for you to accept. You’re asked once per session.",
        "Agent Tools",
        "No agent tools found on this Mac.",
        "Aloud looks for the agent tools you already use. Open one, then come back.",
        "Setting one up adds a short instructions file, a line in the tool’s own instructions, and permission to run Aloud. Remove takes them back out and stops Aloud setting that tool up again. Turning Agent Speak off leaves them in place.",
        "Set Up",
        "Already set up on this Mac",
        "Paste it into %@ in each project you want it in.",
        "Copy the lines to add",
        "%@ isn’t valid JSON, so Aloud left it alone. Add these lines to it by hand.",
        "Couldn’t write %1$@ — %2$@",
        "Let Agents Ask You Out Loud",
        "A coding agent can ask you a question out loud and hear your answer, so you can keep working instead of switching to its window.",
        "This is experimental. You can turn it on or off any time in Settings.",
        "Agents can turn on the microphone",
        "To hear your answer to a question they asked.",
        "Agents can speak through your speakers",
        "That is how the question reaches you.",
        "You always see it happening",
        "The recording indicator appears every time, and names the agent.",
        "Nothing leaves this Mac",
        "Questions and answers stay on this Mac, like the rest of Aloud.",
        "Turn Off",
        "Not Now",
        "Turn On",
        // Picking the voice agents speak with — on the onboarding card and in
        // Settings. The gender words are the choice itself, so an untranslated
        // one is the control's only label left in English, and the stand-in
        // line is the only thing that explains why the voice sounds ordinary
        // on the first run.
        "Voice",
        "Voice gender",
        "Speed",
        "Speaking speed",
        "Female",
        "Male",
        "Hear this voice",
        "Agents ask their questions in this voice.",
        "Using a basic voice for now — Aloud’s own is still downloading.",
        "Getting the voice ready",
        // Heard, not read: the sample the play button speaks.
        "This is me, thinking out loud. How’s the pace?",
        // The pill while an agent has the mic: who is asking, the two answers,
        // and what each phase means. Heard through VoiceOver as often as it is
        // read, and it is the only surface up while the mic is open.
        "Accept — or press the Aloud hotkey",
        "Decline — or press Esc",
        "Waiting for your answer",
        "Listening — this goes to the agent",
        "The agent is speaking",
        "Agent Speak",
        // Two that shipped untranslated until a sweep caught them: a plain
        // toggle, and the fallback name substituted into %@ when the output
        // device has none — English inside an otherwise translated sentence.
        "Play sound effects",
        "this output",
        // Carries a real newline. Listed so the escape survives an edit to the
        // tables: written `\n` in both the source and the .strings file, it is
        // one character by the time either side is parsed.
        "Dictation that stays on your Mac.\nNo account, no cloud, no telemetry.",
        "Suggested Fixes",
        "Suggested",
        "Corrections Aloud saw you make. Accept one and it joins the list below; decline and it won’t be suggested again.",
        "Review %ld suggested fixes",
        "Aloud noticed these corrections. Accepting one fixes that word automatically from now on.",
        "Quit Aloud",
        "Hold %@ to dictate",
        "Welcome to Aloud",
        "Settings",
        "Still listening…",
        "Uninstall Aloud?",
        "Open Aloud at login",
        "%ld dictations",
        "Reduce background noise",
        "Recent Dictations",
        "On this Mac",
        "%@ isn’t taking text right now",
        "%@ didn’t take the text — it’s in History",
        "The front app",
        "That app",
        "%ld suggested fixes",
        "Suggest fixes from your edits",
        "Aloud noticed a fix — review it in the menu bar",
    ]

    private let missingMarker = "\u{7F}missing\u{7F}"

    private func table(for language: String) throws -> Bundle {
        // SPM normalizes .lproj directory names to lowercase when copying
        // resources (pt-BR.lproj → pt-br.lproj), and Bundle's lookup is
        // case-sensitive — try the declared casing first, then lowercase.
        let path = try XCTUnwrap(L10n.bundle.path(forResource: language, ofType: "lproj")
                                 ?? L10n.bundle.path(forResource: language.lowercased(), ofType: "lproj"),
                                 "\(language).lproj missing from module bundle")
        return try XCTUnwrap(Bundle(path: path), "couldn't open \(language).lproj")
    }

    // Every loc("…") literal in the source must have an entry in en.lproj.
    //
    // knownKeys only covers what someone remembered to list, so the failure it
    // cannot see is the common one: add a loc() call, forget the table entry,
    // and the string silently renders English in every other language while
    // every test stays green. That happened three times on the agent-voice
    // work alone — the consent modes, a settings subtitle, a toggle footer —
    // and once before it, when "Play sound effects" was renamed and the new
    // label never localized. This walks the sources instead of a list.
    // Every shipped language, not just English.
    //
    // Pointed at `en` alone this guard could not see the failure it was written
    // for: adding a `loc()` call *and* its English entry, and forgetting the
    // other four, left the suite green while de, es, fr and pt-BR rendered
    // English. The tables happen to agree today — checked, all five — so this
    // closes the gap before it costs another release rather than after.
    func testEveryLocalizedLiteralInTheSourcesHasAnEntryInEveryLanguage() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // AloudTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // package root
            .appendingPathComponent("Sources/Aloud")

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []

        var literals: [(file: String, key: String)] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for key in Self.localizedLiterals(in: text) {
                literals.append((file.lastPathComponent, key))
            }
        }

        XCTAssertGreaterThan(literals.count, 100,
                             "the scanner found almost nothing — it is probably broken")

        var missing: [String] = []
        for language in Self.languages {
            let bundle = try table(for: language)
            for literal in literals {
                let value = bundle.localizedString(forKey: literal.key, value: missingMarker,
                                                   table: nil)
                if value == missingMarker {
                    missing.append("\(language)/\(literal.file): \"\(literal.key)\"")
                }
            }
        }

        XCTAssertTrue(missing.isEmpty,
                      "loc() calls with no entry:\n" + missing.sorted().joined(separator: "\n"))
    }

    // Only literal loc("…") calls. Keys built from variables (Section.title
    // passes rawValue) cannot be read statically and are covered by knownKeys.
    // Escaped quotes inside a key would break this, so they are skipped rather
    // than half-parsed into a wrong answer.
    //
    // What comes out of the file is source text, not the string the compiler
    // builds from it: a two-line tagline is written `…Mac.\nNo account…` here
    // and arrives at loc() as a real newline. The .strings parser unescapes its
    // side too, so a raw comparison reports a key that resolves perfectly at
    // runtime as missing — and "fixing" that would mean adding a second entry
    // keyed on a literal backslash that nothing ever looks up. Unescape instead.
    static func localizedLiterals(in source: String) -> [String] {
        var keys: [String] = []
        var index = source.startIndex
        while let call = source.range(of: "loc(\"", range: index..<source.endIndex) {
            guard let close = source.range(of: "\"", range: call.upperBound..<source.endIndex) else { break }
            let key = String(source[call.upperBound..<close.lowerBound])
            if !key.isEmpty, !key.hasSuffix("\\") { keys.append(unescaped(key)) }
            index = close.upperBound
        }
        return keys
    }

    // The escape sequences a Swift literal can carry into a key. A backslash in
    // front of anything else is left alone rather than guessed at.
    private static func unescaped(_ literal: String) -> String {
        guard literal.contains("\\") else { return literal }
        var out = ""
        var rest = Substring(literal)
        while let slash = rest.firstIndex(of: "\\") {
            out += rest[rest.startIndex..<slash]
            let after = rest.index(after: slash)
            guard after < rest.endIndex else { out += "\\"; return out }
            switch rest[after] {
            case "n":  out += "\n"
            case "t":  out += "\t"
            case "r":  out += "\r"
            case "\"": out += "\""
            case "\\": out += "\\"
            default:   out += String(rest[slash...after])
            }
            rest = rest[rest.index(after: after)...]
        }
        return out + rest
    }

    func testEveryLanguageResolvesKnownKeys() throws {
        for language in Self.languages {
            let bundle = try table(for: language)
            for key in Self.knownKeys {
                let value = bundle.localizedString(forKey: key, value: missingMarker, table: nil)
                XCTAssertNotEqual(value, missingMarker, "\(language): '\(key)' has no entry")
                XCTAssertFalse(value.isEmpty, "\(language): '\(key)' is empty")
            }
        }
    }

    // The wording of the spoken consent prompt, held where the English table
    // can be loaded by name rather than through the process locale.
    //
    // It asks for "yes or no" rather than "accept or decline" because those are
    // the words the recognizer can actually hear: measured on the shipping
    // engine, a spoken "accept" came back as "Except for the same thing", while
    // the same voice saying "yes" transcribed as "Yes." every time. So the
    // question a user is asked out loud may not drift back to a word we cannot
    // hear the answer to — which is a fact about this string, not about
    // whichever language the developer's Mac happens to prefer.
    func testTheSpokenConsentPromptAsksForAWordTheRecognizerCanHear() throws {
        let english = try table(for: "en")
        let format = english.localizedString(forKey: "Let %@ agent listen? Yes or no",
                                             value: missingMarker, table: nil)
        XCTAssertNotEqual(format, missingMarker)
        let asked = String(format: format, "fixing tests")
        XCTAssertTrue(asked.lowercased().contains("yes or no"), asked)
        XCTAssertTrue(asked.contains("fixing tests"), asked)
        XCTAssertFalse(asked.contains("%@"), asked)
        // The words the matcher treats as consent have to include the one the
        // prompt asks for, in every language the prompt is spoken in.
        for language in Self.languages {
            let localized = try table(for: language)
                .localizedString(forKey: "Let %@ agent listen? Yes or no",
                                 value: missingMarker, table: nil)
            XCTAssertNotEqual(localized, missingMarker, language)
            XCTAssertTrue(localized.contains("%@"),
                          "\(language): the session's name has nowhere to go")
        }
    }

    func testFormatKeysProduceFormattedStrings() throws {
        for language in Self.languages {
            let bundle = try table(for: language)
            let hold = bundle.localizedString(forKey: "Hold %@ to dictate", value: missingMarker, table: nil)
            XCTAssertTrue(String(format: hold, "⌥").contains("⌥"), language)
            let percent = bundle.localizedString(forKey: "Downloading voice recognition… %ld%%",
                                                 value: missingMarker, table: nil)
            let formatted = String(format: percent, 42)
            XCTAssertTrue(formatted.contains("42"), language)
            XCTAssertTrue(formatted.contains("%"), language)
        }
    }

    func testTranslationsAreNotEnglishCopies() throws {
        // One long-standing key and one from the agent-voice screens: a table
        // that resolves a key by echoing the English is the failure mode a
        // presence check alone cannot see.
        let englishOnly = ["Quit Aloud", "Let Agents Ask You Out Loud"]
        for language in ["es", "de", "fr", "pt-BR"] {
            let bundle = try table(for: language)
            for key in englishOnly {
                let value = bundle.localizedString(forKey: key, value: missingMarker, table: nil)
                XCTAssertNotEqual(value, key, "\(language): '\(key)' translation missing, English leaked through")
                XCTAssertNotEqual(value, missingMarker, "\(language): '\(key)' has no entry")
            }
        }
    }

    func testLocHelperResolvesFromModuleBundle() {
        XCTAssertEqual(loc("Quit Aloud").isEmpty, false)
        XCTAssertFalse(loc("Hold %@ to dictate", "⌥").isEmpty)
        // The helper must never echo an unresolved format key to the UI.
        XCTAssertFalse(loc("Downloading voice recognition… %ld%%", 50).contains("%ld"))
    }
}
