import Foundation

// When to stop trusting macOS voice processing on a microphone.
//
// Some inputs accept it and then deliver nothing at all — every sample exactly
// zero — which the user experiences as Aloud having gone deaf. The rules for
// noticing that, and for deciding whose fault it was, live here as plain
// functions because they are judgement calls rather than audio code, and
// because getting them wrong is expensive in both directions: too eager and a
// good microphone loses a feature for the sin of being started in a quiet
// moment; too shy and someone dictates into a dead microphone.
enum VoiceProcessingGuard {

    /// Mid-session rescue: rebuild capture without voice processing.
    ///
    /// Only ever fires while voice processing is actually engaged, only once
    /// per session, and only when *nothing* has been heard — not "it was
    /// quiet", but not a single non-zero sample. A live microphone in a silent
    /// room still has a noise floor.
    static func shouldFallBack(voiceProcessingActive: Bool,
                               heardAnything: Bool,
                               alreadyFellBack: Bool) -> Bool {
        voiceProcessingActive && !heardAnything && !alreadyFellBack
    }

    /// End-of-session verdict: should this microphone stop being offered voice
    /// processing in future?
    ///
    /// Earned only by comparison. The fallback already proved voice processing
    /// heard nothing; if raw capture then heard something, the difference is
    /// the feature and this device should never use it again. If raw heard
    /// nothing either, the room was quiet and the feature is off the hook.
    static func shouldDistrustDevice(fellBack: Bool, heardAfterFallback: Bool) -> Bool {
        fellBack && heardAfterFallback
    }
}
