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
    private static var speakers: [String: Speaker] = [:]

    /// The speaker for this voice, built once and kept. `speed` is nil for
    /// callers that only want the instance — warming it, stopping it — and
    /// must not reset a pace the user chose.
    static func speaker(for option: VoiceOption, speed: Double? = nil) -> Speaker {
        if let existing = speakers[option.id] {
            if let speed { existing.speed = VoiceSpeed.clamped(speed) }
            return existing
        }
        let speaker = SpeakerFactory.make(option, speed: speed ?? VoiceSpeed.normal)
        speakers[option.id] = speaker
        return speaker
    }

    /// Stop every voice. For teardown only — anything narrower should stop the
    /// one voice it owns, because these are shared: the agent bridge and the
    /// preview in Settings speak through the same instances, and cutting all
    /// of them to end one is how a sample somebody is listening to disappears.
    static func stopAll() {
        for speaker in speakers.values { speaker.stop() }
    }
}
