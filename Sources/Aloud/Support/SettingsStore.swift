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

    private static func loadHotkey(from defaults: UserDefaults) -> Hotkey? {
        guard let data = defaults.data(forKey: Keys.hotkey) else { return nil }
        return try? JSONDecoder().decode(Hotkey.self, from: data)
    }
}
