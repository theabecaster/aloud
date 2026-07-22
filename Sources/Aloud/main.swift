import AppKit
import Foundation

// Entry: CLI verbs do their work and exit; no args runs the menu bar app.
let cliArgs = Array(CommandLine.arguments.dropFirst())

if let first = cliArgs.first, first.hasPrefix("--") {
    let code = await CLI.run(cliArgs)
    exit(code)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only; no Dock icon
app.run()
