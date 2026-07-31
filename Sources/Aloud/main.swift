import AppKit
import Foundation

// Entry: CLI verbs do their work and exit; no args runs the menu bar app.
let cliArgs = Array(CommandLine.arguments.dropFirst())

// The indicator demo is a CLI verb that needs the app loop: it puts the real
// pill on screen with no microphone, model, or permissions so the indicator can
// be looked at (or screenshotted) on a machine that hasn't granted anything.
// Development tooling, so it goes with the rest of the dev verbs (see CLI.swift).
#if !ALOUD_PROD_CLI
if cliArgs.first == "--indicator-demo" {
    let code = CLI.prepareIndicatorDemo(path: cliArgs.count > 1 ? cliArgs[1] : nil)
    if code != 0 { exit(code) }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
}
#endif

// Agent verbs are bare subcommands, not --flags: `aloud speak "…"` reads
// naturally in the skill files we install, and it keeps the supported surface
// visibly separate from the development tooling. They have to be matched
// explicitly — anything unrecognised must still fall through to launching the
// menu bar app, which is what a bare `open -a Aloud` relies on.
let agentVerbs: Set<String> = ["speak"]

if let first = cliArgs.first, first.hasPrefix("--") || agentVerbs.contains(first) {
    let code = await CLI.run(cliArgs)
    exit(code)
}

// One-time clean slate for installed-app upgrades only. A bare `swift build`
// binary is a development harness, and a UI preview is deliberately isolated;
// neither may ever reset the installed app's history, preferences, model, or
// TCC grants.
let isUIPreview = ProcessInfo.processInfo.environment["ALOUD_UI_PREVIEW"] == "1"
if !isUIPreview, Bundle.main.bundleURL.pathExtension == "app" {
    Migration.runCleanSlateIfNeeded()
}

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
