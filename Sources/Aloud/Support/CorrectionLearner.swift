import Foundation

// Counts the from→to phrase pairs the user keeps making of our dictations,
// and promotes a pair to a suggested Replacement once it has been seen enough
// times. Only these short pairs are ever persisted — never the field text
// they were diffed from — and no standing rule is created until the user
// explicitly accepts one; a wrong Replacement silently corrupts every future
// dictation, so one stray edit must never become a rule on its own.
final class CorrectionLearner: ObservableObject {
    static let shared = CorrectionLearner()

    struct Suggestion: Codable, Equatable, Identifiable {
        let id: UUID
        var from: String        // what Aloud typed
        var to: String          // what the user changed it to
        var count: Int          // times observed
        var firstSeen: Date
        var lastSeen: Date
        var status: Status
    }

    enum Status: String, Codable { case pending, ready, dismissed }

    // The store must not grow forever off one chatty user. Dismissals are the
    // most expensive thing to lose — forgetting one resurrects a suggestion
    // the user already said no to — so the cap sheds pending pairs first,
    // then ready ones, and dismissed pairs only as a last resort.
    static let maxSuggestions = 200

    @Published private(set) var suggestions: [Suggestion] = []
    private let fileURL: URL
    private let queue = DispatchQueue(label: "aloud.corrections")

    init(fileURL: URL = AppPaths.correctionsFile) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            if let decoded = try? JSONDecoder().decode([Suggestion].self, from: data) {
                suggestions = decoded
            } else {
                // Unreadable (corrupt or future-schema) data must not be
                // silently zeroed by the next persist — set it aside instead.
                try? data.write(to: fileURL.appendingPathExtension("bak"), options: .atomic)
                suggestions = []
            }
        } else {
            suggestions = []
        }
    }

    var readySuggestions: [Suggestion] {
        suggestions.filter { $0.status == .ready }.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// What to actually put in front of the user. `observe` turns away pairs a
    /// standing rule already covers, but a rule can arrive after a suggestion
    /// is ready — the user types the same correction in by hand — and asking
    /// about a word that is already handled reads as the app not knowing its
    /// own mind. Answering it would write the rule a second time.
    func openSuggestions(given settings: SettingsStore) -> [Suggestion] {
        readySuggestions.filter { suggestion in
            !settings.replacements.contains {
                $0.pattern.caseInsensitiveCompare(suggestion.from) == .orderedSame
            }
        }
    }

    /// Candidates safe to learn from a passive capture. An explicit History
    /// "Fix" may keep case-only changes — the user typed them at us on
    /// purpose — but a passive capture cannot tell vocabulary casing from
    /// sentence-position casing: a split, joined, or line-initial sentence
    /// re-cases words wholesale, and a standing case rule would re-case every
    /// future dictation. Word-identity changes only.
    static func passiveCandidates(original: String,
                                  corrected: String) -> [CorrectionDiff.Candidate] {
        CorrectionDiff.candidates(original: original, corrected: corrected)
            .filter { $0.from.lowercased() != $0.to.lowercased() }
            // A correction respells the word that was heard; an edit that
            // swaps it for something unrelated is the user writing, and
            // most edits are exactly that (revisions, not corrections).
            .filter { CorrectionGuess.confusable($0.from, $0.to) }
    }

    /// Feed candidates observed from one capture. Matching is case-insensitive
    /// on `from`; `to` is clamped to the latest observed value, because the
    /// user's most recent spelling is the one they settled on. Dismissed pairs
    /// and pairs already covered by a standing replacement are ignored.
    /// Returns the suggestions that crossed `threshold` in THIS call, so the
    /// caller can surface a hint exactly once.
    ///
    /// One sighting is enough to ask. Waiting for a repeat reads as the app
    /// ignoring a fix it plainly saw, and asking costs the user a glance at a
    /// card they can wave off — a "no" is remembered forever, so a pair the
    /// user doesn't want can only ever interrupt them once. What keeps this
    /// from being noise is the gate upstream (`passiveCandidates`): only a
    /// respelling of a word Aloud actually typed gets this far.
    // A pending pair the user hasn't re-confirmed in this long was a one-off,
    // not a habit; letting it linger means a stray edit from a month ago can
    // combine with one today into a suggestion that reads as random.
    static let pendingLifetime: TimeInterval = 30 * 24 * 3600

    @discardableResult
    func observe(_ candidates: [CorrectionDiff.Candidate],
                 settings: SettingsStore,
                 threshold: Int = 1) -> [Suggestion] {
        let now = Date()
        suggestions.removeAll {
            $0.status == .pending && now.timeIntervalSince($0.lastSeen) > Self.pendingLifetime
        }
        var becameReady: [Suggestion] = []
        for candidate in candidates {
            // Correcting the *output* of a standing rule means that rule
            // misfired on this dictation — a problem for the rule (or the
            // booster behind it), never grounds for a new rule that would
            // rewrite the term everywhere it legitimately appears.
            if settings.replacements.contains(where: {
                $0.replacement.caseInsensitiveCompare(candidate.from) == .orderedSame
            }) { continue }
            if settings.replacements.contains(where: {
                $0.pattern.caseInsensitiveCompare(candidate.from) == .orderedSame
            }) { continue }
            if let idx = suggestions.firstIndex(where: {
                $0.from.caseInsensitiveCompare(candidate.from) == .orderedSame
            }) {
                guard suggestions[idx].status != .dismissed else { continue }
                suggestions[idx].count += 1
                suggestions[idx].to = candidate.to
                suggestions[idx].lastSeen = now
                if suggestions[idx].status == .pending, suggestions[idx].count >= threshold {
                    suggestions[idx].status = .ready
                    becameReady.append(suggestions[idx])
                }
            } else {
                var fresh = Suggestion(id: UUID(), from: candidate.from, to: candidate.to,
                                       count: 1, firstSeen: now, lastSeen: now, status: .pending)
                if fresh.count >= threshold {
                    fresh.status = .ready
                    becameReady.append(fresh)
                }
                suggestions.append(fresh)
            }
        }
        enforceCap()
        persist()
        return becameReady
    }

    /// User accepted: the pair becomes a standing Replacement, marked as
    /// learned so the poison guard is allowed to retire it later.
    ///
    /// Answering the same suggestion twice must not write the rule twice. The
    /// UI holds a brief acknowledgement before it reports an accept, so an
    /// "Accept All" — or a decline — can land inside that beat and arrive
    /// first; only a suggestion still awaiting an answer is acted on.
    func accept(_ suggestion: Suggestion, settings: SettingsStore) {
        guard suggestions.contains(where: { $0.id == suggestion.id && $0.status != .dismissed })
        else { return }
        suggestions.removeAll { $0.id == suggestion.id }
        // A pattern the user already has covered — by hand or by an earlier
        // accept — stays as they left it rather than gaining a rival rule.
        if !settings.replacements.contains(where: {
            $0.pattern.caseInsensitiveCompare(suggestion.from) == .orderedSame
        }) {
            settings.replacements.append(
                Replacement(pattern: suggestion.from, replacement: suggestion.to, learned: true))
        }
        persist()
    }

    /// User declined. The pair is kept forever precisely so it can never be
    /// suggested again — deleting it would let the counter start over.
    func dismiss(_ suggestion: Suggestion) {
        guard let idx = suggestions.firstIndex(where: { $0.id == suggestion.id }) else { return }
        suggestions[idx].status = .dismissed
        suggestions[idx].lastSeen = Date()
        persist()
    }

    /// Poison guard, run BEFORE observe on the same candidates: a candidate
    /// that inverts a learned rule means our rule writes something the user
    /// keeps changing back — the rule is wrong, and every dictation it touches
    /// makes it wronger. Retire it (learned rules only; hand-made ones are the
    /// user's to manage), dismiss the pair in both directions so neither side
    /// can be re-learned, and hand back the candidates minus the consumed ones.
    func filteringInverses(_ candidates: [CorrectionDiff.Candidate],
                           settings: SettingsStore) -> [CorrectionDiff.Candidate] {
        var kept: [CorrectionDiff.Candidate] = []
        var retired = false
        for candidate in candidates {
            guard let idx = settings.replacements.firstIndex(where: {
                $0.learned
                    && $0.replacement.caseInsensitiveCompare(candidate.from) == .orderedSame
                    && $0.pattern.caseInsensitiveCompare(candidate.to) == .orderedSame
            }) else {
                kept.append(candidate)
                continue
            }
            settings.replacements.remove(at: idx)
            markDismissed(from: candidate.from, to: candidate.to)
            markDismissed(from: candidate.to, to: candidate.from)
            retired = true
        }
        if retired { persist() }
        return kept
    }

    /// A dismissal means "stop asking about this word" — but a user who later
    /// adds a replacement for that very word by hand has plainly changed their
    /// mind, and the old "no" must not keep future suggestions for it buried.
    func resetDismissals(matchingPattern pattern: String) {
        let before = suggestions.count
        suggestions.removeAll {
            $0.status == .dismissed
                && $0.from.caseInsensitiveCompare(pattern) == .orderedSame
        }
        guard suggestions.count != before else { return }
        persist()
    }

    private func markDismissed(from: String, to: String) {
        let now = Date()
        if let idx = suggestions.firstIndex(where: {
            $0.from.caseInsensitiveCompare(from) == .orderedSame
        }) {
            suggestions[idx].status = .dismissed
            suggestions[idx].lastSeen = now
        } else {
            suggestions.append(Suggestion(id: UUID(), from: from, to: to, count: 1,
                                          firstSeen: now, lastSeen: now, status: .dismissed))
        }
    }

    private func enforceCap() {
        while suggestions.count > Self.maxSuggestions {
            guard let idx = oldestIndex(of: .pending)
                ?? oldestIndex(of: .ready)
                ?? oldestIndex(of: .dismissed) else { return }
            suggestions.remove(at: idx)
        }
    }

    private func oldestIndex(of status: Status) -> Int? {
        suggestions.indices
            .filter { suggestions[$0].status == status }
            .min { suggestions[$0].lastSeen < suggestions[$1].lastSeen }
    }

    private func persist() {
        let snapshot = suggestions
        let url = fileURL
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
