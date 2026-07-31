import AppKit

// Complete removal, since macOS gives apps no hook when the user just trashes
// the bundle: state dir (voice model, history), preferences, permission
// grants, login item, harness configs we wrote into, and finally the app
// itself → Trash.
@MainActor
enum Uninstaller {
    static func confirmAndRun() {
        let alert = NSAlert()
        alert.messageText = loc("Uninstall Aloud?")
        alert.informativeText = loc("This removes the app, the downloaded voice recognition, and all settings and history from this Mac. Nothing is left behind.")
        alert.addButton(withTitle: loc("Uninstall"))
        alert.addButton(withTitle: loc("Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run()
    }

    private static func run() {
        _ = LoginItem.setEnabled(false)
        // Before the bundle goes: the agent harnesses are the only place we
        // wrote outside our own state, and what we wrote there tells an agent
        // to run a binary that is about to stop existing.
        _ = removeHarnessInstalls()
        try? FileManager.default.removeItem(at: AppPaths.stateDir)
        try? FileManager.default.removeItem(at: AppPaths.modelCacheDir)
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

    // MARK: - agent harnesses

    // A harness we could not clean. Collected rather than thrown: uninstall has
    // already been confirmed and the app is on its way to the Trash, so one
    // unreadable settings.json must not strand the other harnesses — or the
    // rest of the uninstall — half done.
    struct HarnessCleanupFailure: Equatable {
        let harness: AgentHarness
        let reason: String
    }

    // Unwrite every harness, whether or not we believe we installed it.
    //
    // Not driven by `SettingsStore.installedHarnesses`: that list is the thing
    // most likely to be wrong by the time somebody uninstalls — defaults get
    // wiped, a home directory gets restored from a backup, an install fails
    // half way. Every removal below is guarded by our own marker or matches
    // only our own allowlist entries, so asking all four costs nothing and
    // catches the cases the list forgot.
    //
    // `nonisolated` so it can be exercised without a main actor; the real home
    // is only reached for by the default argument.
    @discardableResult
    nonisolated static func removeHarnessInstalls(
        using installer: HarnessInstaller = HarnessInstaller(home: HarnessInstaller.userHome)
    ) -> [HarnessCleanupFailure] {
        var failures: [HarnessCleanupFailure] = []
        for harness in AgentHarness.allCases {
            do {
                try installer.uninstall(harness)
            } catch {
                failures.append(HarnessCleanupFailure(
                    harness: harness,
                    reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
        if !failures.isEmpty {
            // Nowhere to show this — the alert is long gone and the app is
            // quitting — but a developer running from a terminal can see which
            // harness kept its stale skill.
            let lines = failures.map { "aloud: couldn't clean \($0.harness.id): \($0.reason)\n" }.joined()
            FileHandle.standardError.write(Data(lines.utf8))
        }
        return failures
    }
}
