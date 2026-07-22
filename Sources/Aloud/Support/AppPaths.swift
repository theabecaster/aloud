import Foundation

// Central place for on-disk locations so tests can redirect everything at once.
enum AppPaths {
    static let bundleID = "com.abrahamgonzalez.aloud"
    static let appName = "Aloud"
    static let githubRepo = "theabecaster/aloud"

    // Overridable root for tests / selftest (ALOUD_STATE_DIR env var).
    static var stateDir: URL {
        if let override = ProcessInfo.processInfo.environment["ALOUD_STATE_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    static var historyFile: URL { stateDir.appendingPathComponent("history.json") }
    static var lastUpdateCheckFile: URL { stateDir.appendingPathComponent("last-update-check") }

    static func ensureStateDir() {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }
}
