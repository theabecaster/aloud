import AppKit
import Combine
import Network
import SwiftUI

extension Notification.Name {
    /// Posted by Settings › About; the delegate runs the check and any install.
    static let aloudCheckForUpdates = Notification.Name("AloudCheckForUpdates")
}

// Menu bar app: NSStatusItem + menu, onboarding/settings windows, silent
// update check. LSUIElement in Info.plist keeps us out of the Dock.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var statusPopover: NSPopover?
    private var menuPreviewWindow: NSWindow?
    private let controller = DictationController()
    private let settingsNavigation = SettingsNavigationModel()
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private let scratchpad = ScratchpadPanel()
    private var pendingUpdate: Updater.LatestRelease?
    private var phaseObservation: AnyCancellable?
    private var downloadObservation: AnyCancellable?
    private var noiseObservation: AnyCancellable?
    private var menuBarTintFade: Timer?
    // What the menu bar glyph is currently drawing: which symbol, and what
    // colour (nil = the menu bar's own, which is what a template image gets).
    // Both are held here because either can change on its own — the symbol
    // when a dictation starts, the colour when filtering is switched — and
    // whichever changes must not drop the other.
    private var iconSymbol = "waveform"
    // How far Aloud's blue has risen through the glyph, 0…1 from the bottom.
    private var iconFill: CGFloat = 0

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
        let isUIPreview = ProcessInfo.processInfo.environment["ALOUD_UI_PREVIEW"] == "1"

        if isUIPreview {
            // Render-only harness: no permission prompts, event taps, model
            // preparation, reachability monitor, or update network request.
        } else if !controller.settings.onboardingComplete || !Permissions.allGranted {
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
        if !isUIPreview {
            resumeDownloadWhenOnline()
        }

        // Mirror recording state in the menu bar icon.
        phaseObservation = controller.$phase.sink { [weak self] phase in
            self?.refreshIcon(for: phase)
        }
        // While the one-time model download runs, the icon carries the
        // percentage so progress is glanceable without opening the menu.
        downloadObservation = controller.$upgradeState.sink { [weak self] state in
            self?.refreshDownloadBadge(for: state)
        }
        // Filtering background noise is the one setting that changes how the
        // app hears you, so it says so where the app always is: the menu bar
        // glyph takes Aloud's blue while it's on, and fades back to the menu
        // bar's own colour when it isn't.
        setMenuBarTint(controller.settings.noiseReduction, animated: false)
        noiseObservation = controller.settings.$noiseReduction.sink { [weak self] on in
            self?.setMenuBarTint(on, animated: true)
        }

        // Settings › About owns the manual check now; the install flow still
        // lives here, next to the pending-update state it mutates.
        NotificationCenter.default.addObserver(forName: .aloudCheckForUpdates,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForUpdates() }
        }

        // Harness hook: ALOUD_OPEN_SETTINGS=1 opens the Settings window at
        // launch, so a pane can be inspected without driving the menu.
        if ProcessInfo.processInfo.environment["ALOUD_OPEN_SETTINGS"] == "1" {
            openSettings()
        }
        // Companion harness for visual QA of the custom status popover. Wait
        // one run-loop turn so AppKit has attached the status button to the
        // menu bar before the popover asks for its anchor geometry.
        if ProcessInfo.processInfo.environment["ALOUD_OPEN_MENU"] == "1" {
            DispatchQueue.main.async { [weak self] in
                if isUIPreview {
                    self?.showStatusMenuPreviewWindow()
                } else {
                    self?.toggleStatusPopover()
                }
            }
        }

        if !isUIPreview {
            silentUpdateCheck()
        }
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
        applyIcon()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggleStatusPopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Aloud"
        }
    }

    private func refreshIcon(for phase: DictationController.Phase) {
        switch phase {
        case .recording: iconSymbol = "waveform.badge.mic"
        case .transcribing: iconSymbol = "waveform.badge.magnifyingglass"
        default: iconSymbol = "waveform"
        }
        applyIcon()
    }

    // A status item's button draws a template image in the menu bar's own
    // colour and ignores `contentTintColor` — which is why tinting it that way
    // produced a black glyph. Colour has to come from the symbol itself, as a
    // palette configuration, and the image then has to stop being a template
    // or the menu bar paints over it again.
    //
    // Filling, the blue is a *solid chip* behind the glyph rather than the
    // glyph itself: a thin blue waveform against the menu bar all but
    // disappears, where a filled shape with the mark knocked out of it in
    // white reads at a glance. The chip rises from the bottom, so sliding the
    // waterline up fills it like a glass and sliding it down empties it from
    // the top, as if it were draining out underneath.
    //
    // Empty goes back to a plain template image, which is what keeps the icon
    // correct in dark mode, in light mode, and inverted under an open menu —
    // a baked-in colour would be wrong the moment the appearance changed.
    private func applyIcon() {
        guard let button = statusItem?.button else { return }
        guard let base = NSImage(systemSymbolName: iconSymbol, accessibilityDescription: "Aloud")
        else { return }
        let level = min(max(iconFill, 0), 1)
        guard level > 0.001 else {
            base.isTemplate = true
            button.image = base
            return
        }
        let blue = NSColor(Color.aloud).usingColorSpace(.sRGB) ?? .systemBlue
        // Above the waterline the glyph is drawn in a real colour rather than
        // left as a template, so it is resolved against the menu bar's own
        // appearance for the moment this frame is drawn.
        var plain = base
        var knockout = base
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            let label = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
            plain = base.withSymbolConfiguration(.init(paletteColors: [label])) ?? base
            knockout = base.withSymbolConfiguration(.init(paletteColors: [.white])) ?? base
        }
        // The bubble is a circle as tall as the menu bar will allow, and the
        // glyph draws down into it as it fills — from its natural size when
        // empty to comfortably inside the circle when full, so there is no
        // jump at either end of the animation.
        let diameter = base.size.height
        let size = NSSize(width: max(base.size.width, diameter), height: diameter)
        let glyphScale = 1 - 0.36 * level
        let composite = NSImage(size: size, flipped: false) { rect in
            let glyphSize = NSSize(width: base.size.width * glyphScale,
                                   height: base.size.height * glyphScale)
            let glyph = NSRect(x: rect.midX - glyphSize.width / 2,
                               y: rect.midY - glyphSize.height / 2,
                               width: glyphSize.width, height: glyphSize.height)
            plain.draw(in: glyph)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY,
                                      width: rect.width, height: rect.height * level)).addClip()
            blue.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - diameter / 2, y: rect.minY,
                                        width: diameter, height: diameter)).fill()
            knockout.draw(in: glyph)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        composite.isTemplate = false
        button.image = composite
    }

    // Fill the glyph with blue, or drain it, over time. Done by hand because
    // nothing about a status item animates on its own, and a colour that
    // snapped would read as a glitch rather than as something filling up.
    // Ease-in-out so it starts and settles gently, the way a poured liquid
    // does rather than a switch being thrown.
    private func setMenuBarTint(_ on: Bool, animated: Bool) {
        guard statusItem?.button != nil else { return }
        menuBarTintFade?.invalidate()
        guard animated else {
            iconFill = on ? 1 : 0
            applyIcon()
            return
        }
        let from = iconFill
        let to: CGFloat = on ? 1 : 0
        let start = Date()
        let duration = 0.7
        menuBarTintFade = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, Date().timeIntervalSince(start) / duration)
                let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                self.iconFill = from + (to - from) * eased
                if t >= 1 {
                    timer.invalidate()
                    self.iconFill = to
                }
                self.applyIcon()
            }
        }
    }

    private func refreshDownloadBadge(for state: TranscriberState) {
        guard let button = statusItem.button else { return }
        if case .downloading(let progress) = state {
            statusItem.length = NSStatusItem.variableLength
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.title = " \(Int(progress * 100))%"
        } else if !button.title.isEmpty {
            button.title = ""
            statusItem.length = NSStatusItem.squareLength
        }
    }

    @objc private func toggleStatusPopover() {
        if let statusPopover, statusPopover.isShown {
            statusPopover.performClose(nil)
            return
        }

        // Opening the popover activates Aloud, so remember who had focus:
        // popover actions that type (retry, use exact words) must hand focus
        // back first or their keystrokes land on the popover itself.
        popoverPreviousApp = NSWorkspace.shared.frontmostApplication

        // The tap can be missing even though permissions read as granted —
        // e.g. Accessibility was granted after launch, or the grant is stale
        // after the app was replaced on disk. Retry cheaply on every open.
        if controller.settings.onboardingComplete, Permissions.allGranted, !controller.isListening {
            _ = controller.startListening()
        }

        let popover = statusPopover ?? {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.delegate = self
            statusPopover = popover
            return popover
        }()
        // No fixed contentSize: the hosting controller publishes the SwiftUI
        // fitting size so the popover hugs its content and grows/shrinks live.
        let host = NSHostingController(rootView: makeStatusMenuView())
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        guard let button = statusItem.button else { return }
        button.highlight(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
    }

    private func closeStatusPopover() {
        statusPopover?.performClose(nil)
    }

    // The app that was frontmost before the popover stole activation.
    private var popoverPreviousApp: NSRunningApplication?

    // Close the popover, give focus back to that app, and only then run —
    // synthetic keystrokes must not fire while Aloud is still frontmost.
    // Activation is asynchronous, hence the beat before the action.
    private func runRestoringFocus(_ action: @escaping () -> Void) {
        closeStatusPopover()
        guard let previous = popoverPreviousApp,
              previous.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !previous.isTerminated else {
            action()
            return
        }
        previous.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { action() }
    }

    private func makeStatusMenuView() -> StatusMenuView {
        var attention: [StatusMenuView.AttentionAction] = []

        if bundleWasReplacedOnDisk {
            attention.append(.init(
                id: "relaunch",
                title: loc("Relaunch to Finish Update"),
                symbol: "arrow.clockwise",
                action: { [weak self] in self?.relaunchFromDisk() }
            ))
        }

        if !Permissions.allGranted || !controller.settings.onboardingComplete {
            attention.append(.init(
                id: "setup",
                title: loc("Finish Setup"),
                symbol: "checkmark.circle",
                action: { [weak self] in
                    self?.closeStatusPopover()
                    self?.openOnboarding()
                }
            ))
        } else if case .modelMissing = controller.upgradeState {
            attention.append(.init(
                id: "download",
                title: loc("Download Voice Recognition"),
                symbol: "arrow.down.circle",
                action: { [weak self] in
                    self?.closeStatusPopover()
                    self?.downloadModel()
                }
            ))
        } else if case .failed = controller.upgradeState {
            attention.append(.init(
                id: "retry-download",
                title: loc("Retry Voice Download"),
                symbol: "arrow.clockwise.circle",
                action: { [weak self] in
                    self?.closeStatusPopover()
                    self?.downloadModel()
                }
            ))
        }

        if let update = pendingUpdate {
            attention.append(.init(
                id: "update",
                title: loc("Update Available (%@)", update.tag),
                symbol: "arrow.down.app",
                action: { [weak self] in
                    self?.closeStatusPopover()
                    self?.applyUpdate()
                }
            ))
        }

        return StatusMenuView(
            controller: controller,
            attentionActions: attention,
            scratchpadVisible: scratchpad.isVisible,
            onOpenHistory: { [weak self] in self?.showSettings(.history) },
            onOpenSettings: { [weak self] in self?.showSettings(.general) },
            onToggleScratchpad: { [weak self] in
                self?.closeStatusPopover()
                self?.toggleScratchpad()
            },
            onCopyLast: { [weak self] in self?.copyLastDictation() },
            onRetryLast: { [weak self] in
                self?.runRestoringFocus { self?.retryLastDictation() }
            },
            onUseExactWords: { [weak self] in
                self?.runRestoringFocus { self?.undoEnhancement() }
            },
            onQuit: { NSApp.terminate(nil) }
        )
    }

    /// A normal window only for automated visual inspection. Computer-control
    /// harnesses can inspect windows reliably but don't expose transient
    /// menu-bar popovers. The hosted SwiftUI content is exactly the same.
    private func showStatusMenuPreviewWindow() {
        if let menuPreviewWindow {
            present(menuPreviewWindow)
            return
        }
        let window = NSWindow(contentViewController:
            NSHostingController(rootView: makeStatusMenuView()))
        window.title = "Aloud Menu Preview"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        menuPreviewWindow = window
        present(window)
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
        // A window's very first orderFront can race the hosting view's initial
        // layout: the switches' knobs are placed during that first display
        // pass, and when the window reaches the screen before it finishes —
        // seen on the settings window right after install — every toggle
        // draws as an empty track until clicked. Finish layout and drawing
        // before the window is ever visible.
        if !window.isVisible {
            window.layoutIfNeeded()
            window.displayIfNeeded()
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
        window.title = loc("Welcome to Aloud")
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

    @objc private func undoEnhancement() {
        controller.undoLastEnhancement()
    }

    @objc private func retryLastDictation() {
        controller.retryLastDictation()
    }

    @objc private func copyLastDictation() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(controller.lastTranscription, forType: .string)
    }

    @objc private func toggleScratchpad() {
        scratchpad.toggle()
    }

    @objc private func openSettings() {
        showSettings(.general)
    }

    private func showSettings(_ section: SettingsView.Section) {
        closeStatusPopover()
        controller.stopSessionForSettings()
        settingsNavigation.section = section
        if let settingsWindow { present(settingsWindow); return }
        let window = NSWindow(contentViewController:
            NSHostingController(rootView: SettingsView(controller: controller,
                                                       navigation: settingsNavigation)))
        window.title = loc("Aloud Settings")
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 820, height: 620))
        window.minSize = NSSize(width: 760, height: 540)
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
                    alert.messageText = latest == nil ? loc("Couldn’t check for updates")
                                                      : loc("You’re up to date")
                    alert.informativeText = latest == nil
                        ? loc("Check your internet connection and try again.")
                        : loc("Aloud %@ is the latest version.", Updater.currentVersion())
                    alert.runModal()
                }
            }
        }
    }

    private func releaseNotesLink(_ url: URL) -> NSView {
        let link = NSMutableAttributedString(
            string: loc("View release notes"),
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
        alert.messageText = loc("Update to Aloud %@?", update.tag)
        alert.informativeText = loc("Aloud will update and reopen. Takes a few seconds.")
        alert.accessoryView = releaseNotesLink(update.pageURL)
        alert.addButton(withTitle: loc("Update and Relaunch"))
        alert.addButton(withTitle: loc("Later"))
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
                    alert.messageText = loc("Update didn’t finish")
                    alert.informativeText = loc("%@. You can download it from the releases page instead.", reason)
                    alert.addButton(withTitle: loc("Open Releases Page"))
                    alert.addButton(withTitle: loc("Cancel"))
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(Updater.releasesPage)
                    }
                }
            }
        }
    }
}
