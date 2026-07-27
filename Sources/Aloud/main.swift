import AppKit
import Foundation

// Entry: CLI verbs do their work and exit; no args runs the menu bar app.
let cliArgs = Array(CommandLine.arguments.dropFirst())

// The indicator demo is a CLI verb that needs the app loop: it puts the real
// pill on screen with no microphone, model, or permissions so the indicator can
// be looked at (or screenshotted) on a machine that hasn't granted anything.
if cliArgs.first == "--indicator-demo" {
    let code = CLI.prepareIndicatorDemo(path: cliArgs.count > 1 ? cliArgs[1] : nil)
    if code != 0 { exit(code) }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
}

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
