import AVFoundation
import Foundation

// Which voice an agent speaks with, and the one thing the user picks about it.
//
// That one thing is gender. macOS installs dozens of voices per language and
// names them all — Samantha, Karen, Rishi — but a name is only worth offering
// if the person has heard it before, and nobody has. What they can answer
// without being taught anything is "female or male", so that is the whole
// question, and Aloud picks the best voice it has on that side.
//
// The engines stay an implementation detail (docs §5a, and the rule that holds
// for Transcriber holds here): this file is the only place that knows a choice
// is served by the enhanced engine or by the system one.

enum VoiceGender: String, CaseIterable, Codable, Sendable, Identifiable {
    case female
    case male

    var id: String { rawValue }

    var label: String {
        switch self {
        case .female: return loc("Female")
        case .male: return loc("Male")
        }
    }
}

struct VoiceOption: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// Aloud's own downloaded voice, and which engine and preset serve it.
        /// Two engines rather than one because neither covers both sides well:
        /// the female voice's engine ships a single English voice pack, and
        /// the male one's engine is the only other with a voice worth using.
        case enhanced(NeuralEngine, style: String)
        case system(String)      // an AVSpeechSynthesisVoice identifier
    }

    /// Identifies this voice to the parts of Aloud that cache one — never
    /// stored in Settings, which keeps only the gender. Deliberately not the
    /// AVSpeechSynthesisVoice identifier: that encodes the quality tier
    /// (`…voice.compact.en-AU.Karen` becomes `…voice.super-compact.…`, and
    /// again when a premium version is downloaded), so a cache keyed on it
    /// would rebuild every time macOS swapped the bundle underneath.
    let id: String
    /// The voice's own name. Not shown anywhere in the UI — it is here for
    /// `--doctor`, where "why does it sound like that" is a real question and
    /// "female" is not an answer anyone can act on.
    let name: String
    let gender: VoiceGender
    /// Where the accent is from, localized ("United States"). nil when the
    /// voice does not declare one.
    let region: String?
    let source: Source

    var isEnhanced: Bool {
        if case .enhanced = source { return true }
        return false
    }
}

enum VoiceCatalog {
    /// Which side to speak from when the user hasn't said.
    static let defaultGender: VoiceGender = .female

    // Aloud's own voices, one per side, each a preset of the engine that does
    // that side best. They are always *offered* — readiness only decides
    // whether the user hears one today or hears the Mac's own voice while it
    // arrives (see `EnhancedVoices`).
    //
    // The pair was chosen by ear from every preset both engines ship; the
    // samples are reproducible with
    // `--speak-bench <line> --engine <name> --voice <style> --out <dir>`.
    static let enhanced: [VoiceGender: VoiceOption] = [
        .female: VoiceOption(id: "aloud.enhanced.female",
                             // Names identify a voice in `--doctor` and in
                             // logs; nothing in the UI shows them.
                             name: "Aloud Female",
                             gender: .female,
                             region: Locale.current.localizedString(forRegionCode: "US"),
                             source: .enhanced(.kokoro, style: "")),
        .male: VoiceOption(id: "aloud.enhanced.male",
                           name: "Aloud Male",
                           gender: .male,
                           region: Locale.current.localizedString(forRegionCode: "US"),
                           source: .enhanced(.supertonic, style: "M1")),
    ]

    // MARK: - The choice

    // Built once and kept, because building it is not cheap and reading it is
    // constant: `AVSpeechSynthesisVoice.speechVoices()` walks every installed
    // voice bundle, and SwiftUI asks which voice is selected on every redraw —
    // including every frame of a slider drag. Enumerating the Mac's voices
    // sixty times a second is exactly as slow as it sounds.
    //
    // The cost of keeping it is that a voice installed while Settings is open
    // does not appear until something calls `refresh()`, which the picker does
    // each time it comes on screen.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: (language: String,
                                                   system: [VoiceGender: VoiceOption])?

    /// Look at the Mac again. Cheap to call; the rebuild happens on next read.
    static func refresh() {
        cacheLock.lock()
        cache = nil
        cacheLock.unlock()
    }

    /// The macOS voice that stands in for this side while Aloud's own is being
    /// fetched — and speaks for it permanently in a language Aloud's own voice
    /// does not cover. nil if the Mac has none.
    static func systemVoice(for gender: VoiceGender,
                            language: String = Locale.current.identifier) -> VoiceOption? {
        systemVoices(language: language)[gender]
    }

    /// Aloud's own voice for this side, if it can serve the language at all.
    /// Present whether or not its assets are downloaded — that is
    /// `EnhancedVoices`' question, not this one.
    static func enhancedVoice(for gender: VoiceGender,
                              language: String = Locale.current.identifier) -> VoiceOption? {
        guard let option = enhanced[gender] else { return nil }
        guard case .enhanced(let engine, _) = option.source else { return nil }
        return engine.speaks(language) ? option : nil
    }

    /// The genders Aloud can actually speak in. Both, on any Mac that has
    /// either its own voice or one of the OS's for that side.
    static var availableGenders: [VoiceGender] {
        let offered = VoiceGender.allCases.filter {
            enhancedVoice(for: $0) != nil || systemVoice(for: $0) != nil
        }
        // A Mac with nothing usable at all still gets both: the fallback
        // speaker says something regardless, and a picker with no options is
        // worse than one whose choice barely matters.
        return offered.isEmpty ? VoiceGender.allCases : offered
    }

    /// The voice that will speak right now: Aloud's own if its assets are
    /// here, otherwise the Mac's best on that side. Falls back across the
    /// gender line rather than to silence — a Mac with only male voices
    /// installed should still be able to ask a question.
    static func resolved(gender: VoiceGender?) -> VoiceOption {
        let wanted = gender ?? defaultGender
        for candidate in [wanted, defaultGender] + VoiceGender.allCases {
            if let mine = enhancedVoice(for: candidate), EnhancedVoices.isReady(mine) {
                return mine
            }
            if let theirs = systemVoice(for: candidate) { return theirs }
        }
        // Nothing installed and nothing downloaded: hand back Aloud's own
        // entry anyway. `SpeakerFactory` turns it into the system synthesizer's
        // default voice, which is the one thing that always exists.
        return enhanced[wanted] ?? enhanced[defaultGender]!
    }

    /// True while this side is being served by a stand-in — Aloud's own voice
    /// exists for it but isn't on disk yet. The picker says so; nothing offers
    /// a button, because the fetch is not the user's job (see `EnhancedVoices`).
    static func isStandingIn(_ gender: VoiceGender) -> Bool {
        guard let mine = enhancedVoice(for: gender) else { return false }
        return !EnhancedVoices.isReady(mine)
    }

    // MARK: - Building it

    private static func systemVoices(language: String) -> [VoiceGender: VoiceOption] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cache, cache.language == language { return cache.system }
        let built = bestSystemVoices(languageCode: String(language.prefix(2)).lowercased())
        cache = (language, built)
        return built
    }

    // macOS's own voices, filtered down to the ones a person would recognise as
    // a voice, then narrowed to the best of each gender. Two filters do that
    // work:
    //
    //   * `com.apple.voice.` — the modern voice bundles. Novelty voices
    //     ("Bubbles", "Trinoids") and the robotic Eloquence family live under
    //     other prefixes, and neither belongs in the mouth of an agent asking
    //     you a question.
    //   * a declared gender — it is the only thing being chosen here, so a
    //     voice that will not say cannot be chosen.
    private static func bestSystemVoices(languageCode: String) -> [VoiceGender: VoiceOption] {
        let region = Locale.current.region?.identifier
        var best: [VoiceGender: (score: Int, option: VoiceOption)] = [:]

        for voice in AVSpeechSynthesisVoice.speechVoices() {
            guard voice.identifier.hasPrefix("com.apple.voice."),
                  voice.language.lowercased().hasPrefix(languageCode),
                  let gender = gender(of: voice) else { continue }
            let score = rank(voice, homeRegion: region)
            guard score > (best[gender]?.score ?? Int.min) else { continue }
            best[gender] = (score, VoiceOption(id: "system.\(voice.language).\(voice.name)",
                                               name: voice.name,
                                               gender: gender,
                                               region: regionName(of: voice),
                                               source: .system(voice.identifier)))
        }
        return best.mapValues(\.option)
    }

    // Better voices first, and among equals the one that speaks the way the
    // user's own region does — an American Mac should not answer in the South
    // African voice just because it enumerated earlier.
    private static func rank(_ voice: AVSpeechSynthesisVoice, homeRegion: String?) -> Int {
        var score: Int
        switch voice.quality {
        case .premium: score = 300
        case .enhanced: score = 200
        default: score = 100
        }
        if let homeRegion, voice.language.hasSuffix("-\(homeRegion)") { score += 50 }
        return score
    }

    private static func gender(of voice: AVSpeechSynthesisVoice) -> VoiceGender? {
        switch voice.gender {
        case .female: return .female
        case .male: return .male
        default: return nil
        }
    }

    // "en-GB" → "United Kingdom", in the user's language. Localized by the OS
    // rather than by our own tables, so a new voice region never arrives as an
    // untranslated string.
    private static func regionName(of voice: AVSpeechSynthesisVoice) -> String? {
        let parts = voice.language.split(separator: "-")
        guard parts.count > 1 else { return nil }
        return Locale.current.localizedString(forRegionCode: String(parts[1]))
    }
}

// How fast the chosen voice speaks. One scale for both engines, centred on 1 —
// the pace each voice was built to run at — so the number means the same thing
// whichever voice is speaking.
enum VoiceSpeed {
    static let normal: Double = 1.0
    static let slowest: Double = 0.7
    static let fastest: Double = 1.4
    static let step: Double = 0.05

    // NaN checked first: a stored value can be anything, and every comparison
    // against NaN is false, so a plain min/max clamp passes it straight through
    // to the engine.
    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return slowest }
        return min(max(value, slowest), fastest)
    }

    /// "1.2×", for the readout next to the slider. Trailing zeros are dropped
    /// because "1×" is what a person would say out loud, and the step is
    /// hundredths so two decimals is as precise as the slider can be.
    static func label(_ value: Double) -> String {
        var text = String(format: "%.2f", clamped(value))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "×"
    }
}
