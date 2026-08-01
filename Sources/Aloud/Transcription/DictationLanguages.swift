import Foundation
import Speech

// The languages dictation understands — the engine's capability surface,
// safe to show in UI (unlike the engines themselves, which stay unnamed).
//
// Two tiers, and the difference is the one the app already has a word for.
// `supported` is what full-accuracy dictation covers. Everything else that can
// be heard at all is heard by basic dictation — the same reduced-accuracy
// engine that already covers the window before the model finishes downloading,
// carrying the same "Basic" tag on the pill. Declaring one of those languages
// keeps Aloud on basic dictation for good rather than only until the download
// lands, which is why the picker says so before the choice is made.
enum DictationLanguages {
    // ISO 639-1 codes the primary engine covers: 25 European languages,
    // verified against the engine SDK's documentation for the pinned version.
    // Keep in sync when the model version changes.
    static let supported: [String] = [
        "en", "es", "fr", "de", "it", "pt", "nl", "sv", "da", "fi",
        "ro", "hu", "et", "lv", "lt", "mt", "pl", "cs", "sk", "sl",
        "hr", "ru", "uk", "bg", "el",
    ]

    /// Full accuracy, as opposed to only reachable through basic dictation.
    static func isFullQuality(_ code: String) -> Bool {
        supported.contains(code)
    }

    // Languages only basic dictation can hear. Read off the system rather than
    // hardcoded, so the set moves with macOS instead of promising assets a Mac
    // can't install.
    //
    // The system's own list, and treated as the close proxy it is rather than
    // a guarantee: newer systems run basic dictation through a second pipeline
    // whose coverage can be a subset, and it is only knowable asynchronously,
    // which is no use to a picker. So a language here is offered, and if it
    // then can't be set up, Settings says so against that language instead of
    // the app pretending it is listening in it.
    static let basicOnly: [String] = {
        var seen = Set(supported)
        var codes: [String] = []
        for locale in SFSpeechRecognizer.supportedLocales() {
            guard let code = locale.language.languageCode?.identifier,
                  seen.insert(code).inserted else { continue }
            codes.append(code)
        }
        return codes
    }()

    /// True when this Mac can hear the language at all — the picker only ever
    /// offers languages that pass, and a stored one that stops passing (an OS
    /// that dropped an asset) is still shown so the user can take it out.
    static func isDictatable(_ code: String) -> Bool {
        isFullQuality(code) || basicOnly.contains(code)
    }

    static func displayName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}
