import Foundation

// The languages dictation understands — the engine's capability surface,
// safe to show in UI (unlike the engine itself, which stays unnamed).
enum DictationLanguages {
    // ISO 639-1 codes the primary engine covers: 25 European languages,
    // verified against the engine SDK's documentation for the pinned version.
    // Keep in sync when the model version changes.
    static let supported: [String] = [
        "en", "es", "fr", "de", "it", "pt", "nl", "sv", "da", "fi",
        "ro", "hu", "et", "lv", "lt", "mt", "pl", "cs", "sk", "sl",
        "hr", "ru", "uk", "bg", "el",
    ]

    static func displayName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}
