import Foundation

// One speaker per voice, shared by everything that speaks.
//
// Two things need a voice — the agent bridge, and the preview button in
// Settings — and before this they each built their own. That meant loading the
// same CoreML chain twice (once per copy, seconds each and hundreds of
// megabytes resident), and it meant warming one did nothing for the other: a
// user who had already heard the preview still waited for the first question.
//
// Keyed on the voice's id rather than on the gender, so a side whose voice
// changes underneath it — Aloud's own arriving and replacing the Mac's
// stand-in — gets a new speaker rather than the old one under a new name.
@MainActor
enum SpeakerPool {
    private struct Entry {
        let option: VoiceOption
        let speaker: Speaker
    }

    private static var entries: [String: Entry] = [:]

    /// The speaker for this voice, built once and kept. `speed` is nil for
    /// callers that only want the instance — warming it, stopping it — and
    /// must not reset a pace the user chose.
    static func speaker(for option: VoiceOption, speed: Double? = nil) -> Speaker {
        if let existing = entries[option.id] {
            if let speed { existing.speaker.speed = VoiceSpeed.clamped(speed) }
            return existing.speaker
        }
        let speaker = SpeakerFactory.make(option, speed: speed ?? VoiceSpeed.normal)
        entries[option.id] = Entry(option: option, speaker: speaker)
        return speaker
    }

    /// Take an already-loaded speaker as this voice's, so the work of loading
    /// it is not done twice. The download path builds one to fetch the assets
    /// with; without this it was thrown away and the very next call built and
    /// loaded the same CoreML chain again.
    static func adopt(_ speaker: Speaker, for option: VoiceOption) {
        guard entries[option.id] == nil else { return }
        entries[option.id] = Entry(option: option, speaker: speaker)
    }

    /// Keep one of Aloud's own voices resident, not both.
    ///
    /// Each enhanced voice is its own CoreML chain, so a user who auditions
    /// both sides in Settings pinned two of them for the life of the process —
    /// against the stated intent that "only the chosen side is resident". The
    /// system voices are left alone: they hold no models, and dropping the one
    /// standing in for a side mid-download would discard a speaker something
    /// else may still be speaking through.
    static func keepOnlyEnhanced(_ keep: VoiceOption) {
        for (id, entry) in entries where id != keep.id {
            guard case .enhanced = entry.option.source else { continue }
            entry.speaker.stop()
            entries.removeValue(forKey: id)
        }
    }

    /// Stop every voice. For teardown only — anything narrower should stop the
    /// one voice it owns, because these are shared: the agent bridge and the
    /// preview in Settings speak through the same instances, and cutting all
    /// of them to end one is how a sample somebody is listening to disappears.
    static func stopAll() {
        for entry in entries.values { entry.speaker.stop() }
    }
}
