import Foundation

// Installs upgraded over any pre-existing version can carry state that breaks
// the app in confusing ways (stale permission grants keyed to a replaced
// bundle, half-migrated settings). The first GUI launch of this version puts
// everyone on a clean slate: state dir (voice model, history), preferences,
// and permission grants are removed, so onboarding and the permission flow
// run fresh. A marker written afterwards guarantees this happens exactly once.
enum Migration {
    private static let markerKey = "cleanSlateDone"

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
