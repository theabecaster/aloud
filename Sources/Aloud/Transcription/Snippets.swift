import Foundation

// A spoken trigger that expands to canned text: say "my email" (or "insert my
// email") as the whole dictation and the expansion is typed instead. Matching
// is deliberately all-or-nothing — a trigger buried mid-sentence stays plain
// words, so ordinary dictation can never fire a snippet by accident.
struct Snippet: Codable, Equatable, Identifiable {
    var id = UUID()
    var trigger: String     // the spoken phrase
    var expansion: String   // what gets typed in its place
}

enum SnippetMatcher {
    // The expansion for an utterance, or nil when nothing matches. Runs on the
    // polished transcript, so comparisons must forgive what dictation adds:
    // capitalization, surrounding whitespace, and a trailing period.
    static func expansion(for utterance: String, snippets: [Snippet]) -> String? {
        let spoken = normalize(utterance)
        guard !spoken.isEmpty else { return nil }
        for snippet in snippets {
            let trigger = normalize(snippet.trigger)
            guard !trigger.isEmpty else { continue }
            if spoken == trigger
                || spoken == "insert \(trigger)"
                || spoken == "insert my \(trigger)" {
                return snippet.expansion
            }
        }
        return nil
    }

    private static func normalize(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let last = t.last, ".,!?;:".contains(last) { t.removeLast() }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
