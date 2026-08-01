import Foundation

// Getting Agent Speak in front of people who never went looking for it.
//
// The bridge is only reachable through the instructions we write into each
// harness: an agent with no skill file and no note in its global instructions
// has no idea the CLI exists, so it does what it has always done — ends its
// turn and waits at a keyboard nobody is sitting at. Until now those files were
// written only when someone opened Settings and clicked Install, which means
// every existing user had the feature and none of them had the thing that makes
// it work.
//
// So it happens by itself, at two moments:
//
//   1. **After an update.** Once per app version, every detected harness gets
//      the instructions. Version-keyed rather than once-ever, because the text
//      changes with the app and a Mac that grew a new harness since the last
//      launch should get it too.
//   2. **When onboarding finishes** with the feature left on, which is the
//      first launch case: the harnesses are detected and written the moment the
//      user stops being asked questions, not the next time they happen to
//      relaunch.
//
// What it will not do is overrule anybody. A harness the user removed is
// remembered by `HarnessInstaller` and skipped here for good, and the whole
// thing is gated on the feature being switched on at all.
@MainActor
enum AgentAutoInstall {
    // The app version this Mac was last auto-installed for. Stored raw rather
    // than through SettingsStore: nothing about it is a user preference, and it
    // is read once at launch before anything else has an opinion.
    private static let versionKey = "agentAutoInstallVersion"

    static func runIfNeeded(settings: SettingsStore = .shared,
                            defaults: UserDefaults = .standard,
                            version: String = Updater.currentVersion(),
                            installer: HarnessInstaller? = nil) {
        guard settings.experimentalAgentVoice else { return }
        guard defaults.string(forKey: versionKey) != version else { return }
        defaults.set(version, forKey: versionKey)
        install(settings: settings, installer: installer)
    }

    // The onboarding path. Deliberately not version-gated: someone who has just
    // finished onboarding has never had this run, whatever version marker an
    // earlier install left behind, and the install is a no-op when the files
    // are already correct.
    static func runAfterOnboarding(settings: SettingsStore = .shared,
                                   defaults: UserDefaults = .standard,
                                   version: String = Updater.currentVersion(),
                                   installer: HarnessInstaller? = nil) {
        guard settings.experimentalAgentVoice else { return }
        defaults.set(version, forKey: versionKey)
        install(settings: settings, installer: installer)
    }

    private static func install(settings: SettingsStore, installer: HarnessInstaller?) {
        let installer = installer ?? HarnessInstaller(home: HarnessInstaller.userHome)
        let installed = installer.installAllDetected()
        if !installed.isEmpty {
            DevDiag.note("install", "auto-installed: \(installed.map(\.id).joined(separator: ", "))")
        }
        // Reconciled against disk rather than accumulated from what this pass
        // changed. The pane and the bridge's `status` both read this list, and
        // it can be out of step with the files for reasons that have nothing to
        // do with us — defaults reset, a home directory restored from a backup,
        // an install recorded by an older build. Asking the disk is the only
        // answer that cannot drift; the alternative under-reports the feature's
        // reach and makes `namesHarnessWhenSpeaking` pick the wrong wording.
        let onDisk = installer.detect().filter(\.isInstalled).map(\.harness.id).sorted()
        guard settings.installedHarnesses != onDisk else { return }
        settings.installedHarnesses = onDisk
    }
}
