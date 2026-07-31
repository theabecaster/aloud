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
        "An agent wants to listen — say accept or decline",
        "%@ wants to listen — say accept or decline",
        // Settings → Agents and the onboarding opt-in. Agent voice hands local
        // processes the mic and the speakers, so the screens that say so — and
        // the switch that takes it back — cannot fall back to English.
        "Agent voice",
        "Agents can ask to speak through your speakers and hear your answer. Turning this off refuses every request — anything set up below stays, so switching it back on doesn’t mean starting over.",
        "Consent",
        "The recording indicator always shows while an agent is listening, and nothing leaves this Mac.",
        // The consent modes. The names are what a segmented control shows, the
        // sentences are what the mode costs — a mode nobody can read is a
        // permission decision made blind.
        "Open",
        "Agents can start listening right away. The recording indicator always shows when they do.",
        "Confirm on screen",
        "Nothing reaches the agent until you accept on screen.",
        "Confirm by voice",
        "Aloud asks out loud and waits for you to say accept — no need to look at the screen.",
        "Agent Tools",
        "No agent tools found on this Mac.",
        "Aloud looks for the agent tools you already use. Open one, then come back.",
        "Aloud writes a short instructions file so an agent knows it can talk to you. Remove deletes that file again.",
        "Install",
        "Already set up on this Mac",
        "Lives in each project — paste it into %@ in the repos you want it in.",
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

    func testFormatKeysProduceFormattedStrings() throws {
        for language in Self.languages {
            let bundle = try table(for: language)
            let hold = bundle.localizedString(forKey: "Hold %@ to dictate", value: missingMarker, table: nil)
            XCTAssertTrue(String(format: hold, "⌥").contains("⌥"), language)
            let percent = bundle.localizedString(forKey: "Improving accuracy… %ld%%",
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
        XCTAssertFalse(loc("Improving accuracy… %ld%%", 50).contains("%ld"))
    }
}
