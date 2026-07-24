import Foundation
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

// On-device translation for "translate this to Spanish" commands.
//
// The system Translation framework is used when it can be: macOS 26 added a
// headless TranslationSession initializer (installedSource:target:) that works
// without a SwiftUI host — but only for language pairs whose models are
// already installed (it can never prompt a download from here). Anything it
// can't do returns nil and the caller falls back to the language-model rewrite
// path, whose short-text translation quality is acceptable. Everything stays
// on the Mac either way.

// "Spanish" → Locale.Language("es"), via ICU's English display names. Pure and
// deterministic so it's testable without any model.
enum LanguageResolver {
    static func language(named name: String) -> Locale.Language? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        let english = Locale(identifier: "en_US")
        for code in Locale.LanguageCode.isoLanguageCodes {
            guard let display = english.localizedString(forLanguageCode: code.identifier)
            else { continue }
            if display.lowercased() == wanted {
                return Locale.Language(languageCode: code)
            }
        }
        return nil
    }
}

enum SystemTranslator {
    // nil = the system can't translate this here and now (old OS, unknown
    // source, language pair not installed) — not an error, just "use the
    // model instead".
    static func translate(_ text: String, to target: Locale.Language) async -> String? {
        #if canImport(Translation)
        guard #available(macOS 26.0, *) else { return nil }
        guard let dominant = NLLanguageRecognizer.dominantLanguage(for: text) else { return nil }
        let source = Locale.Language(identifier: dominant.rawValue)
        guard source.languageCode != target.languageCode else { return nil }
        guard await LanguageAvailability().status(from: source, to: target) == .installed
        else { return nil }
        let session = TranslationSession(installedSource: source, target: target)
        let translated = try? await session.translate(text).targetText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let translated, !translated.isEmpty else { return nil }
        return translated
        #else
        return nil
        #endif
    }
}
