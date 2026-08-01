import AppKit
import Foundation

// Entry: CLI verbs do their work and exit; no args runs the menu bar app.
let cliArgs = Array(CommandLine.arguments.dropFirst())

// Agent verbs are bare subcommands, not --flags: `aloud speak "…"` reads
// naturally in the skill files we install, and it keeps the supported surface
// visibly separate from the development tooling. They have to be matched
// explicitly — anything unrecognised must still fall through to launching the
// menu bar app, which is what a bare `open -a Aloud` relies on.
let agentVerbs: Set<String> = ["claim", "release", "speak", "listen", "status"]

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

// The consent defaults, before anything reads them — SettingsStore latches its
// values the first time `.shared` is touched, and this has to be the state it
// finds. Runs for development builds too: they are how the defaults get tested.
Migration.applyAgentConsentDefaultsIfNeeded()

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
