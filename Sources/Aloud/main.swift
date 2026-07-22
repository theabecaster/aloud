import AppKit
import Foundation

// Entry: CLI verbs do their work and exit; no args runs the menu bar app.
let cliArgs = Array(CommandLine.arguments.dropFirst())

if let first = cliArgs.first, first.hasPrefix("--") {
    let code = await CLI.run(cliArgs)
    exit(code)
}

// One-time clean slate for upgrades over any previous version — must run
// before the state dir, lock file, and SettingsStore touch old state.
Migration.runCleanSlateIfNeeded()

// Singleton: a second GUI launch hands off to the running one and exits.
// flock on a file in the state dir — crash-safe (the lock dies with the pid).
AppPaths.ensureStateDir()
let lockPath = AppPaths.stateDir.appendingPathComponent("gui.lock").path
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o644)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    // Already running — activate it (only meaningful from a real .app) and bow out.
    if Bundle.main.bundleURL.path.hasSuffix(".app") {
        NSWorkspace.shared.open(Bundle.main.bundleURL)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only; no Dock icon
app.run()
