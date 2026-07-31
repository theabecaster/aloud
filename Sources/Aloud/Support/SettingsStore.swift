import Combine
import CoreGraphics
import Foundation

// All user settings, UserDefaults-backed (redirectable suite for tests).
// ObservableObject so SwiftUI settings/onboarding bind directly.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = SettingsStore.resolveDefaults()) {
        self.defaults = defaults
        hotkey = Self.loadHotkey(from: defaults) ?? .default
        handsFreeHotkey = Self.loadOptionalHotkey(from: defaults, key: Keys.handsFreeHotkey,
                                                  fallback: .defaultHandsFreeKey)
        commandHotkey = Self.loadOptionalHotkey(from: defaults, key: Keys.commandHotkey,
                                                fallback: .defaultCommandKey)
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        microphoneUID = defaults.string(forKey: Keys.microphoneUID)
        onboardingComplete = defaults.bool(forKey: Keys.onboardingComplete)
        historyLimit = defaults.object(forKey: Keys.historyLimit) as? Int ?? 50
        polishLevel = (defaults.string(forKey: Keys.polishLevel)).flatMap(PolishLevel.init) ?? .standard
        replacements = (defaults.data(forKey: Keys.replacements))
            .flatMap { try? JSONDecoder().decode([Replacement].self, from: $0) } ?? []
        snippets = (defaults.data(forKey: Keys.snippets))
            .flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? []
        appModes = (defaults.data(forKey: Keys.appModes))
            .flatMap { try? JSONDecoder().decode([AppModeRule].self, from: $0) } ?? []
        soundCues = defaults.object(forKey: Keys.soundCues) as? Bool ?? true
        indicatorPosition = (defaults.data(forKey: Keys.indicatorPosition))
            .flatMap { try? JSONDecoder().decode(CGPoint.self, from: $0) }
        statsWords = defaults.object(forKey: Keys.statsWords) as? Int ?? 0
        statsSeconds = defaults.object(forKey: Keys.statsSeconds) as? Double ?? 0
        statsDictations = defaults.object(forKey: Keys.statsDictations) as? Int ?? 0
        liveTyping = defaults.object(forKey: Keys.liveTyping) as? Bool ?? true
        let storedLanguages = defaults.object(forKey: Keys.declaredLanguages) as? [String] ?? []
        declaredLanguages = storedLanguages.isEmpty
            ? [Locale.current.language.languageCode?.identifier ?? "en"]
            : storedLanguages
        pressEnterCommand = defaults.bool(forKey: Keys.pressEnterCommand)
        noiseReduction = defaults.object(forKey: Keys.noiseReduction) as? Bool ?? false
        learnCorrections = defaults.object(forKey: Keys.learnCorrections) as? Bool ?? true
        installedHarnesses = defaults.object(forKey: Keys.installedHarnesses) as? [String] ?? []
        agentConsentMode = (defaults.string(forKey: Keys.agentConsentMode))
            .flatMap(AgentConsentMode.init) ?? .confirmByVoice
        // Off until a harness is installed, because before that there is
        // nothing to grant access to. Installing the first one is the act of
        // consent (see noteHarnessesChanged); the switch is how it gets taken
        // back without unpicking every config file. Once the user has touched
        // it, their choice wins and installs stop moving it.
        let configured = defaults.bool(forKey: Keys.agentVoiceConfigured)
        agentVoiceEnabled = configured
            ? defaults.bool(forKey: Keys.agentVoiceEnabled)
            : !(defaults.object(forKey: Keys.installedHarnesses) as? [String] ?? []).isEmpty
    }

    private static func resolveDefaults() -> UserDefaults {
        if let suite = ProcessInfo.processInfo.environment["ALOUD_DEFAULTS_SUITE"],
           let d = UserDefaults(suiteName: suite) { return d }
        return .standard
    }

    private enum Keys {
        static let hotkey = "hotkey"
        static let handsFreeHotkey = "handsFreeHotkey"
        static let commandHotkey = "commandHotkey"
        static let launchAtLogin = "launchAtLogin"
        static let microphoneUID = "microphoneUID"
        static let onboardingComplete = "onboardingComplete"
        static let historyLimit = "historyLimit"
        static let polishLevel = "polishLevel"
        static let replacements = "replacements"
        static let snippets = "snippets"
        static let appModes = "appModes"
        static let soundCues = "soundCues"
        static let indicatorPosition = "indicatorPosition"
        static let statsWords = "statsWords"
        static let statsSeconds = "statsSeconds"
        static let statsDictations = "statsDictations"
        static let liveTyping = "liveTyping"
        static let declaredLanguages = "declaredLanguages"
        static let pressEnterCommand = "pressEnterCommand"
        static let noiseReduction = "noiseReduction"
        static let learnCorrections = "learnCorrections"
        static let deafDevices = "noiseReductionDeafDevices"
        static let agentVoiceEnabled = "agentVoiceEnabled"
        static let agentVoiceConfigured = "agentVoiceConfigured"
        static let agentConsentMode = "agentConsentMode"
        static let installedHarnesses = "installedHarnesses"
    }

    @Published var hotkey: Hotkey {
        didSet { if let data = try? JSONEncoder().encode(hotkey) { defaults.set(data, forKey: Keys.hotkey) } }
    }
    // Optional dedicated hands-free key: press to start a locked session,
    // press again to finish. nil = double-tap the main key only.
    @Published var handsFreeHotkey: Hotkey? {
        didSet {
            if let hk = handsFreeHotkey, let data = try? JSONEncoder().encode(hk) {
                defaults.set(data, forKey: Keys.handsFreeHotkey)
            } else {
                defaults.set(Data(), forKey: Keys.handsFreeHotkey)  // cleared, not unset
            }
        }
    }
    // Optional command key: hold it, say what you want done — the transcript
    // drives an edit or a short generation instead of being typed. nil = off.
    @Published var commandHotkey: Hotkey? {
        didSet {
            if let hk = commandHotkey, let data = try? JSONEncoder().encode(hk) {
                defaults.set(data, forKey: Keys.commandHotkey)
            } else {
                defaults.set(Data(), forKey: Keys.commandHotkey)  // cleared, not unset
            }
        }
    }
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }
    @Published var microphoneUID: String? {
        didSet { defaults.set(microphoneUID, forKey: Keys.microphoneUID) }
    }
    @Published var onboardingComplete: Bool {
        didSet { defaults.set(onboardingComplete, forKey: Keys.onboardingComplete) }
    }
    @Published var historyLimit: Int {
        didSet { defaults.set(historyLimit, forKey: Keys.historyLimit) }
    }
    @Published var polishLevel: PolishLevel {
        didSet { defaults.set(polishLevel.rawValue, forKey: Keys.polishLevel) }
    }
    @Published var replacements: [Replacement] {
        didSet { if let data = try? JSONEncoder().encode(replacements) { defaults.set(data, forKey: Keys.replacements) } }
    }
    @Published var snippets: [Snippet] {
        didSet { if let data = try? JSONEncoder().encode(snippets) { defaults.set(data, forKey: Keys.snippets) } }
    }
    // Per-app mode overrides (Settings → Modes); they beat the built-in table.
    @Published var appModes: [AppModeRule] {
        didSet { if let data = try? JSONEncoder().encode(appModes) { defaults.set(data, forKey: Keys.appModes) } }
    }
    @Published var soundCues: Bool {
        didSet { defaults.set(soundCues, forKey: Keys.soundCues) }
    }
    // Where the user parked the recording pill, as fractions (0…1) of the
    // screen's visible frame — survives display size changes. nil = default
    // bottom-center.
    @Published var indicatorPosition: CGPoint? {
        didSet {
            if let p = indicatorPosition, let data = try? JSONEncoder().encode(p) {
                defaults.set(data, forKey: Keys.indicatorPosition)
            } else {
                defaults.removeObject(forKey: Keys.indicatorPosition)
            }
        }
    }
    // Type words as they're spoken instead of all at once on release.
    @Published var liveTyping: Bool {
        didSet { defaults.set(liveTyping, forKey: Keys.liveTyping) }
    }
    // Languages the user dictates in (ISO codes, primary first). The primary
    // engine detects its languages automatically; the declared list steers
    // the basic-dictation engine's locale and, when a single language is
    // declared, hints the primary. Default: the system language. Never empty.
    @Published var declaredLanguages: [String] {
        didSet { defaults.set(declaredLanguages, forKey: Keys.declaredLanguages) }
    }
    // Ending a dictation with "press enter" sends Return after the text.
    // Off by default: dictating *about* pressing enter must never submit
    // someone's chat message unasked.
    @Published var pressEnterCommand: Bool {
        didSet { defaults.set(pressEnterCommand, forKey: Keys.pressEnterCommand) }
    }
    // Run the mic through macOS voice processing: room noise, keyboard clatter
    // and whatever the Mac's own speakers are playing get attenuated before
    // anything reaches the model. Off until asked for: it changes how the user
    // sounds, and a first dictation that comes back thinner than the room it
    // was spoken in is confusing in a way that a first dictation carrying some
    // background noise is not. Someone dictating in a café can turn it on from
    // the pill the moment they want it; someone who never needed it never has
    // to work out why their voice was being processed.
    @Published var noiseReduction: Bool {
        didSet { defaults.set(noiseReduction, forKey: Keys.noiseReduction) }
    }
    // Notice when the user edits a just-typed dictation and offer the fix as a
    // standing Replacement. Off = no capture and nothing new persisted; pairs
    // already learned stay where they are.
    @Published var learnCorrections: Bool {
        didSet { defaults.set(learnCorrections, forKey: Keys.learnCorrections) }
    }

    // MARK: agent voice

    // The master switch. Off refuses every agent call — `listen` and `speak`
    // both — with a reason that tells the agent to stop asking rather than to
    // retry. Setting it marks the preference as the user's own, so later
    // harness installs never move it back.
    @Published var agentVoiceEnabled: Bool {
        didSet {
            defaults.set(agentVoiceEnabled, forKey: Keys.agentVoiceEnabled)
            defaults.set(true, forKey: Keys.agentVoiceConfigured)
        }
    }
    // How an agent's request to listen is approved. Chosen on the onboarding
    // install page rather than buried here, because that is the screen where
    // the user is actually weighing it up.
    @Published var agentConsentMode: AgentConsentMode {
        didSet { defaults.set(agentConsentMode.rawValue, forKey: Keys.agentConsentMode) }
    }
    // Harness ids the installer has wired up. Drives whether the spoken prompt
    // names the caller: with one installed "an agent wants to listen" is
    // clearer than naming it, so the name only appears when there is genuine
    // ambiguity to resolve.
    @Published var installedHarnesses: [String] {
        didSet { defaults.set(installedHarnesses, forKey: Keys.installedHarnesses) }
    }

    var namesHarnessWhenSpeaking: Bool { installedHarnesses.count > 1 }

    // Called after the installer adds or removes harnesses. Turning the
    // feature on for the first install is the whole point of the default; it
    // must never override a user who has already made the choice themselves.
    func noteHarnessesChanged() {
        guard !defaults.bool(forKey: Keys.agentVoiceConfigured) else { return }
        let derived = !installedHarnesses.isEmpty
        guard derived != agentVoiceEnabled else { return }
        agentVoiceEnabled = derived
        // agentVoiceEnabled's didSet marks it configured; undo that, since this
        // was our inference and not the user's decision.
        defaults.set(false, forKey: Keys.agentVoiceConfigured)
    }

    // Microphones that went completely silent under macOS voice processing.
    // Some inputs — Bluetooth headsets in particular — accept it and then
    // deliver nothing at all, which reads to the user as "Aloud stopped
    // hearing me". Once a device has done that, it never gets voice processing
    // again, so the failure happens at most once per microphone instead of
    // every time it's plugged in. Not a user setting; there is nothing here
    // for anyone to decide.
    var deafUnderNoiseReduction: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.deafDevices) ?? []) }
        set { defaults.set(Array(newValue), forKey: Keys.deafDevices) }
    }

    func rememberDeafUnderNoiseReduction(_ uid: String) {
        var set = deafUnderNoiseReduction
        guard set.insert(uid).inserted else { return }
        deafUnderNoiseReduction = set
    }

    // Lifetime dictation totals (words spoken, seconds of speech, sessions) —
    // history is capped, so these accumulate separately. Local only, like
    // everything else.
    @Published var statsWords: Int {
        didSet { defaults.set(statsWords, forKey: Keys.statsWords) }
    }
    @Published var statsSeconds: Double {
        didSet { defaults.set(statsSeconds, forKey: Keys.statsSeconds) }
    }
    @Published var statsDictations: Int {
        didSet { defaults.set(statsDictations, forKey: Keys.statsDictations) }
    }

    func recordDictation(words: Int, seconds: TimeInterval) {
        statsWords += words
        statsSeconds += seconds
        statsDictations += 1
    }

    /// Two slots whose keys overlap — the same combo, or one combo contained
    /// in the other — means one of them silently never fires, or fires on the
    /// way into the other. The dictation key wins every tie, and the
    /// hands-free key beats the command key; losers are cleared rather than
    /// left in Settings looking like they still do something. Returns true
    /// when anything was dropped.
    @discardableResult
    func dropCollidingKeys() -> Bool {
        var dropped = false
        if let hf = handsFreeHotkey, hf.overlaps(hotkey) {
            handsFreeHotkey = nil
            dropped = true
        }
        if let command = commandHotkey,
           command.overlaps(hotkey) || handsFreeHotkey.map(command.overlaps) == true {
            commandHotkey = nil
            dropped = true
        }
        return dropped
    }

    private static func loadHotkey(from defaults: UserDefaults) -> Hotkey? {
        guard let data = defaults.data(forKey: Keys.hotkey) else { return nil }
        return try? JSONDecoder().decode(Hotkey.self, from: data)
    }

    // Optional key slots ship with a default. Never-set → the default; an
    // empty-data sentinel remembers "the user cleared this" across launches
    // (removing the key entirely would resurrect the default).
    private static func loadOptionalHotkey(from defaults: UserDefaults, key: String,
                                           fallback: Hotkey) -> Hotkey? {
        guard let data = defaults.data(forKey: key) else { return fallback }
        guard !data.isEmpty else { return nil }
        return (try? JSONDecoder().decode(Hotkey.self, from: data)) ?? fallback
    }
}
