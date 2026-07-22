import AppKit

// Complete removal, since macOS gives apps no hook when the user just trashes
// the bundle: state dir (voice model, history), preferences, permission
// grants, login item, and finally the app itself → Trash.
@MainActor
enum Uninstaller {
    static func confirmAndRun() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Aloud?"
        alert.informativeText = "This removes the app, the downloaded voice recognition, and all settings and history from this Mac. Nothing is left behind."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run()
    }

    private static func run() {
        _ = LoginItem.setEnabled(false)
        try? FileManager.default.removeItem(at: AppPaths.stateDir)
        UserDefaults.standard.removePersistentDomain(forName: AppPaths.bundleID)
        UserDefaults.standard.synchronize()
        for service in ["Accessibility", "Microphone"] {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", service, AppPaths.bundleID]
            try? reset.run()
            reset.waitUntilExit()
        }
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            NSApp.terminate(nil)
        }
    }
}
