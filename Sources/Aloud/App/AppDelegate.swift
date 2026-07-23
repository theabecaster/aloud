import AppKit
import Combine
import Network
import SwiftUI

// Menu bar app: NSStatusItem + menu, onboarding/settings windows, silent
// update check. LSUIElement in Info.plist keeps us out of the Dock.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let controller = DictationController()
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var pendingUpdate: Updater.LatestRelease?
    private var phaseObservation: AnyCancellable?

    // File identity of our executable at launch. If the bundle on disk is
    // later replaced (manual update) or trashed, this instance is a zombie:
    // clicking the new app only focuses us, so the update never runs.
    private lazy var launchExecutableID: UInt64? = Self.executableFileID()

    private static func executableFileID() -> UInt64? {
        guard let path = Bundle.main.executablePath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        else { return nil }
        return (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    private var bundleWasReplacedOnDisk: Bool {
        guard let atLaunch = launchExecutableID else { return false }
        return Self.executableFileID() != atLaunch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = launchExecutableID
        AppPaths.ensureStateDir()
        setupStatusItem()

        if !controller.settings.onboardingComplete || !Permissions.allGranted {
            showOnboarding()
        } else {
            _ = controller.startListening()
            Task {
                // Relaunched before the model download ever finished: cover
                // with basic dictation (quiet activation never prompts) while
                // the download resumes underneath.
                await controller.activateFallback(interactive: false)
                await controller.prepareModel()
            }
        }
        resumeDownloadWhenOnline()

        // Mirror recording state in the menu bar icon.
        phaseObservation = controller.$phase.sink { [weak self] phase in
            self?.refreshIcon(for: phase)
        }

        silentUpdateCheck()
    }

    // The one-time model download must survive network loss: whenever
    // connectivity returns and the model still isn't on disk, kick the
    // download again (the transcriber serializes concurrent attempts).
    private var pathMonitor: NWPathMonitor?

    private func resumeDownloadWhenOnline() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self else { return }
                switch self.controller.upgradeState {
                case .modelMissing, .failed: await self.controller.prepareModel()
                default: break
                }
            }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // The user may have flipped permissions in System Settings — recover,
        // but only when the tap is actually missing. Opening our own menu or
        // Settings also activates the app, and restarting mid-session would
        // rebuild the hotkey engine and orphan a live recording (dead Esc).
        if controller.settings.onboardingComplete, Permissions.allGranted, !controller.isListening {
            _ = controller.startListening()
        }
    }

    // MARK: status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform",
                                   accessibilityDescription: "Aloud")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func refreshIcon(for phase: DictationController.Phase) {
        guard let button = statusItem.button else { return }
        let name: String
        switch phase {
        case .recording: name = "waveform.badge.mic"
        case .transcribing: name = "waveform.badge.magnifyingglass"
        default: name = "waveform"
        }
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Aloud")
    }

    // Rebuild the menu each open so status lines are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        // The tap can be missing even though permissions read as granted —
        // e.g. Accessibility was granted after launch, or the grant is stale
        // after the app was replaced on disk. Retry cheaply on every open.
        if controller.settings.onboardingComplete, Permissions.allGranted, !controller.isListening {
            _ = controller.startListening()
        }

        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if bundleWasReplacedOnDisk {
            menu.addItem(withTitle: "Relaunch to Finish Update…",
                         action: #selector(relaunchFromDisk), keyEquivalent: "").target = self
        }

        if !Permissions.allGranted || !controller.settings.onboardingComplete {
            menu.addItem(withTitle: "Finish Setup…",
                         action: #selector(openOnboarding), keyEquivalent: "").target = self
        } else if case .modelMissing = controller.upgradeState {
            menu.addItem(withTitle: "Download Voice Recognition…",
                         action: #selector(downloadModel), keyEquivalent: "").target = self
        } else if case .failed = controller.upgradeState {
            menu.addItem(withTitle: "Retry Voice Download…",
                         action: #selector(downloadModel), keyEquivalent: "").target = self
        } else if controller.usingFallback {
            // Dictation already works (basic); the accuracy upgrade is still
            // landing in the background. Informational only.
            let title: String
            if case .downloading(let p) = controller.upgradeState {
                title = "Improving accuracy… \(Int(p * 100))%"
            } else {
                title = "Improving accuracy…"
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        if !controller.lastTranscription.isEmpty {
            menu.addItem(withTitle: "Copy Last Dictation",
                         action: #selector(copyLastDictation), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Settings…",
                     action: #selector(openSettings), keyEquivalent: ",").target = self

        if let update = pendingUpdate {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "Update Available (\(update.tag))…",
                                  action: #selector(applyUpdate), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        } else {
            menu.addItem(withTitle: "Check for Updates…",
                         action: #selector(checkForUpdates), keyEquivalent: "").target = self
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Aloud",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func statusLine() -> String {
        if Permissions.microphone != .granted { return "Microphone access needed" }
        if Permissions.accessibility != .granted { return "Accessibility access needed" }
        switch controller.transcriberState {
        case .modelMissing: return "Voice setup needed"
        case .downloading(let p): return "Downloading voice recognition… \(Int(p * 100))%"
        case .loading: return "Warming up…"
        case .failed: return "Voice download didn’t finish"
        case .ready:
            if controller.settings.onboardingComplete, !controller.isListening {
                return "Dictation key isn’t working — try reopening Aloud"
            }
            return "Hold \(controller.settings.hotkey.displayName) to dictate"
        }
    }

    // MARK: windows

    // Menu bar apps have no Dock icon to click, so a window left on another
    // Space or screen looks like "nothing happened". Every show pulls the
    // window to the Space and screen the user is actually on.
    private func present(_ window: NSWindow) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        if let screen {
            let f = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: f.midX - size.width / 2,
                                          y: f.midY - size.height / 2 + f.height * 0.04))
        } else {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func showOnboarding() {
        if let onboardingWindow { present(onboardingWindow); return }
        let view = OnboardingView(controller: controller) { [weak self] in
            guard let self else { return }
            controller.settings.onboardingComplete = true
            onboardingWindow?.close()
            onboardingWindow = nil
            _ = controller.startListening()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to Aloud"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // Stay visible above System Settings while the user flips permissions;
        // our instructions are the map for what to do over there.
        window.level = .floating
        onboardingWindow = window
        present(window)
    }

    @objc private func openOnboarding() { showOnboarding() }

    // Quit this stale instance and start whatever is on disk in our place.
    @objc private func relaunchFromDisk() {
        let path = Bundle.main.bundlePath
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 0.5; /usr/bin/open \"\(path)\""]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    @objc private func downloadModel() {
        Task { await controller.prepareModel() }
    }

    @objc private func copyLastDictation() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(controller.lastTranscription, forType: .string)
    }

    @objc private func openSettings() {
        controller.stopSessionForSettings()
        if let settingsWindow { present(settingsWindow); return }
        let window = NSWindow(contentViewController:
            NSHostingController(rootView: SettingsView(controller: controller)))
        window.title = "Aloud Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        settingsWindow = window
        present(window)
    }

    // MARK: updates

    private func silentUpdateCheck() {
        guard Updater.shouldAutoCheckNow() else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let latest = Updater.fetchLatestRelease(),
                  Updater.semverLess(Updater.currentVersion(), latest.tag) else { return }
            DispatchQueue.main.async { self?.pendingUpdate = latest }
        }
    }

    @objc private func checkForUpdates() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let latest = Updater.fetchLatestRelease()
            DispatchQueue.main.async {
                guard let self else { return }
                if let latest, Updater.semverLess(Updater.currentVersion(), latest.tag) {
                    self.pendingUpdate = latest
                    self.applyUpdate()
                } else {
                    let alert = NSAlert()
                    alert.messageText = latest == nil ? "Couldn’t check for updates"
                                                      : "You’re up to date"
                    alert.informativeText = latest == nil
                        ? "Check your internet connection and try again."
                        : "Aloud \(Updater.currentVersion()) is the latest version."
                    alert.runModal()
                }
            }
        }
    }

    private func releaseNotesLink(_ url: URL) -> NSView {
        let link = NSMutableAttributedString(
            string: "View release notes",
            attributes: [.link: url, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 220, height: 16))
        view.textStorage?.setAttributedString(link)
        view.isEditable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        return view
    }

    @objc private func applyUpdate() {
        guard let update = pendingUpdate else { return }
        let alert = NSAlert()
        alert.messageText = "Update to Aloud \(update.tag)?"
        alert.informativeText = "Aloud will update and reopen. Takes a few seconds."
        alert.accessoryView = releaseNotesLink(update.pageURL)
        alert.addButton(withTitle: "Update and Relaunch")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let dest = Updater.updatableBundlePath() else {
            NSWorkspace.shared.open(Updater.releasesPage)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Updater.downloadAndStage(update, into: dest)
            DispatchQueue.main.async {
                switch result {
                case .relaunching:
                    NSApp.terminate(nil)
                case .failed(let reason):
                    let alert = NSAlert()
                    alert.messageText = "Update didn’t finish"
                    alert.informativeText = "\(reason). You can download it from the releases page instead."
                    alert.addButton(withTitle: "Open Releases Page")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(Updater.releasesPage)
                    }
                }
            }
        }
    }
}
