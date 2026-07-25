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
        "Quit Aloud",
        "Hold %@ to dictate",
        "Welcome to Aloud",
        "Settings",
        "Still listening…",
        "Uninstall Aloud?",
        "Open Aloud at login",
        "%ld dictations",
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
        for language in ["es", "de", "fr", "pt-BR"] {
            let bundle = try table(for: language)
            let value = bundle.localizedString(forKey: "Quit Aloud", value: missingMarker, table: nil)
            XCTAssertNotEqual(value, "Quit Aloud", "\(language): translation missing, English leaked through")
            XCTAssertNotEqual(value, missingMarker, language)
        }
    }

    func testLocHelperResolvesFromModuleBundle() {
        XCTAssertEqual(loc("Quit Aloud").isEmpty, false)
        XCTAssertFalse(loc("Hold %@ to dictate", "⌥").isEmpty)
        // The helper must never echo an unresolved format key to the UI.
        XCTAssertFalse(loc("Improving accuracy… %ld%%", 50).contains("%ld"))
    }
}
