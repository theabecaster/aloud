import Foundation

// Installs upgraded over any pre-existing version can carry state that breaks
// the app in confusing ways (stale permission grants keyed to a replaced
// bundle, half-migrated settings). The first GUI launch of this version puts
// everyone on a clean slate: state dir (voice model, history), preferences,
// and permission grants are removed, so onboarding and the permission flow
// run fresh. A marker written afterwards guarantees this happens exactly once.
enum Migration {
    private static let markerKey = "cleanSlateDone"
    private static let agentConsentDefaultKey = "agentConsentOpenDefaultApplied"

    // Agent Speak ships letting agents open the microphone without asking
    // first, and without the spoken confirmation — the pill and its name badge
    // are the disclosure, and the feature is behind an explicit opt-in already.
    // Asking every time cost the first question of every session a round of
    // "yes", which is the moment the feature is meant to save.
    //
    // Applied to existing installs as well as fresh ones, because they are
    // carrying a default nobody chose: the old build shipped confirm-by-voice
    // whether or not the user ever looked at the setting. Exactly once, keyed
    // on a marker — the whole point is that anything the user picks *after*
    // this is theirs and is never touched again.
    //
    // Written straight to `UserDefaults` rather than through `SettingsStore`
    // because it has to land before the store reads them, which happens the
    // first time anything asks for `.shared`.
    static func applyAgentConsentDefaultsIfNeeded(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: agentConsentDefaultKey) else { return }
        // Only where nothing was chosen. `SettingsStore` writes this key from a
        // `didSet`, which does not fire while it is reading its initial values —
        // so the key being present at all means a person went to the pane and
        // picked something. Without this check the migration could not tell
        // "never chose" from "chose to be asked out loud", and quietly turned
        // the second one into no prompt at all: a stricter setting, deliberately
        // made, replaced by the loosest one, permanently.
        let untouched = defaults.object(forKey: "agentConsentMode") == nil
        if untouched {
            defaults.set(AgentConsentMode.open.rawValue, forKey: "agentConsentMode")
            defaults.set(false, forKey: "agentAsksOutLoud")
        }
        defaults.set(true, forKey: agentConsentDefaultKey)
    }

    static func runCleanSlateIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: markerKey) else { return }
        let hadOldInstall = defaults.object(forKey: "onboardingComplete") != nil
            || FileManager.default.fileExists(atPath: AppPaths.stateDir.path)
        if hadOldInstall {
            try? FileManager.default.removeItem(at: AppPaths.stateDir)
            try? FileManager.default.removeItem(at: AppPaths.modelCacheDir)
            UserDefaults.standard.removePersistentDomain(forName: AppPaths.bundleID)
            for service in ["Accessibility", "Microphone"] {
                let reset = Process()
                reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                reset.arguments = ["reset", service, AppPaths.bundleID]
                try? reset.run()
                reset.waitUntilExit()
            }
        }
        defaults.set(true, forKey: markerKey)
    }
}
