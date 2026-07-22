import Foundation
import Combine

// All user settings, UserDefaults-backed (redirectable suite for tests).
// ObservableObject so SwiftUI settings/onboarding bind directly.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = SettingsStore.resolveDefaults()) {
        self.defaults = defaults
        hotkey = Self.loadHotkey(from: defaults) ?? .default
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        microphoneUID = defaults.string(forKey: Keys.microphoneUID)
        onboardingComplete = defaults.bool(forKey: Keys.onboardingComplete)
        historyLimit = defaults.object(forKey: Keys.historyLimit) as? Int ?? 50
        polishLevel = (defaults.string(forKey: Keys.polishLevel)).flatMap(PolishLevel.init) ?? .standard
        replacements = (defaults.data(forKey: Keys.replacements))
            .flatMap { try? JSONDecoder().decode([Replacement].self, from: $0) } ?? []
        soundCues = defaults.object(forKey: Keys.soundCues) as? Bool ?? true
        liveTyping = defaults.bool(forKey: Keys.liveTyping)
    }

    private static func resolveDefaults() -> UserDefaults {
        if let suite = ProcessInfo.processInfo.environment["ALOUD_DEFAULTS_SUITE"],
           let d = UserDefaults(suiteName: suite) { return d }
        return .standard
    }

    private enum Keys {
        static let hotkey = "hotkey"
        static let launchAtLogin = "launchAtLogin"
        static let microphoneUID = "microphoneUID"
        static let onboardingComplete = "onboardingComplete"
        static let historyLimit = "historyLimit"
        static let polishLevel = "polishLevel"
        static let replacements = "replacements"
        static let soundCues = "soundCues"
        static let liveTyping = "liveTyping"
    }

    @Published var hotkey: Hotkey {
        didSet { if let data = try? JSONEncoder().encode(hotkey) { defaults.set(data, forKey: Keys.hotkey) } }
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
    @Published var soundCues: Bool {
        didSet { defaults.set(soundCues, forKey: Keys.soundCues) }
    }
    // Beta: type words as they're spoken instead of all at once on release.
    // Defaults to off so everyone gets the proven experience unless they opt in.
    @Published var liveTyping: Bool {
        didSet { defaults.set(liveTyping, forKey: Keys.liveTyping) }
    }

    private static func loadHotkey(from defaults: UserDefaults) -> Hotkey? {
        guard let data = defaults.data(forKey: Keys.hotkey) else { return nil }
        return try? JSONDecoder().decode(Hotkey.self, from: data)
    }
}
