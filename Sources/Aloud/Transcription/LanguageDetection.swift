import Foundation
import NaturalLanguage

// Best-effort language of a finished transcript, recorded on its history
// entry so later features (per-language stats, smarter clean-up) have it
// without re-deriving anything. Detection over a handful of words is
// guesswork — below the length floor or under-confident means nil, because
// storing no language beats storing a wrong one.
enum LanguageDetection {
    private static let minimumLength = 12
    private static let minimumConfidence = 0.6

    static func code(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumLength else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= minimumConfidence else { return nil }
        return language.rawValue
    }
}
