import Foundation

// Spoken commands recognized at the very end of a dictation. Only the tail is
// ever interpreted — "press enter" mid-sentence is just words.
enum TrailingCommand {
    // "… press enter" / "… and press return." → the text without the phrase,
    // or nil when the dictation doesn't end with the command.
    private static let pressEnter = try! NSRegularExpression(
        pattern: #"(?:(?:[,.;:\s]|\band\b|\bthen\b)*)\bpress (?:enter|return)\b[.!?]?\s*$"#,
        options: [.caseInsensitive])

    static func stripPressEnter(_ text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pressEnter.firstMatch(in: text, range: range),
              let stripped = Range(match.range, in: text) else { return nil }
        return String(text[..<stripped.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
