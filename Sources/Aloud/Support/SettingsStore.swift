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
        handsFreeHotkey = (defaults.data(forKey: Keys.handsFreeHotkey))
            .flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) }
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        microphoneUID = defaults.string(forKey: Keys.microphoneUID)
        onboardingComplete = defaults.bool(forKey: Keys.onboardingComplete)
        historyLimit = defaults.object(forKey: Keys.historyLimit) as? Int ?? 50
        polishLevel = (defaults.string(forKey: Keys.polishLevel)).flatMap(PolishLevel.init) ?? .standard
        replacements = (defaults.data(forKey: Keys.replacements))
            .flatMap { try? JSONDecoder().decode([Replacement].self, from: $0) } ?? []
        appModes = (defaults.data(forKey: Keys.appModes))
            .flatMap { try? JSONDecoder().decode([AppModeRule].self, from: $0) } ?? []
        soundCues = defaults.object(forKey: Keys.soundCues) as? Bool ?? true
        indicatorPosition = (defaults.data(forKey: Keys.indicatorPosition))
            .flatMap { try? JSONDecoder().decode(CGPoint.self, from: $0) }
        statsWords = defaults.object(forKey: Keys.statsWords) as? Int ?? 0
        statsSeconds = defaults.object(forKey: Keys.statsSeconds) as? Double ?? 0
        statsDictations = defaults.object(forKey: Keys.statsDictations) as? Int ?? 0
        liveTyping = defaults.object(forKey: Keys.liveTyping) as? Bool ?? true
        handsFree = defaults.object(forKey: Keys.handsFree) as? Bool ?? true
        pressEnterCommand = defaults.bool(forKey: Keys.pressEnterCommand)
    }

    private static func resolveDefaults() -> UserDefaults {
        if let suite = ProcessInfo.processInfo.environment["ALOUD_DEFAULTS_SUITE"],
           let d = UserDefaults(suiteName: suite) { return d }
        return .standard
    }

    private enum Keys {
        static let hotkey = "hotkey"
        static let handsFreeHotkey = "handsFreeHotkey"
        static let launchAtLogin = "launchAtLogin"
        static let microphoneUID = "microphoneUID"
        static let onboardingComplete = "onboardingComplete"
        static let historyLimit = "historyLimit"
        static let polishLevel = "polishLevel"
        static let replacements = "replacements"
        static let appModes = "appModes"
        static let soundCues = "soundCues"
        static let indicatorPosition = "indicatorPosition"
        static let statsWords = "statsWords"
        static let statsSeconds = "statsSeconds"
        static let statsDictations = "statsDictations"
        static let liveTyping = "liveTyping"
        static let handsFree = "handsFree"
        static let pressEnterCommand = "pressEnterCommand"
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
                defaults.removeObject(forKey: Keys.handsFreeHotkey)
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
    // Double-press the dictation key → keep listening until Esc. On by default.
    @Published var handsFree: Bool {
        didSet { defaults.set(handsFree, forKey: Keys.handsFree) }
    }
    // Ending a dictation with "press enter" sends Return after the text.
    // Off by default: dictating *about* pressing enter must never submit
    // someone's chat message unasked.
    @Published var pressEnterCommand: Bool {
        didSet { defaults.set(pressEnterCommand, forKey: Keys.pressEnterCommand) }
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

    private static func loadHotkey(from defaults: UserDefaults) -> Hotkey? {
        guard let data = defaults.data(forKey: Keys.hotkey) else { return nil }
        return try? JSONDecoder().decode(Hotkey.self, from: data)
    }
}
