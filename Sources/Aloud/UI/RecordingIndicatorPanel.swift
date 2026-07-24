import AppKit
import SwiftUI

// The small floating "I'm listening" pill: a non-activating panel near the
// bottom-center of the active screen, visible on all Spaces, never steals focus.
// Shows a live level meter while recording, a spinner while transcribing, and
// short hint messages. Subtle fade/scale in and out.
@MainActor
final class RecordingIndicatorPanel {
    private var panel: NSPanel?
    private let model = IndicatorModel()
    private var levelTimer: Timer?
    // Bumped by present() and hide() so a hide's fade-out completion can tell
    // whether a show snuck in behind it (hands-free is a cancel immediately
    // followed by a re-show) and must not order the panel out.
    private var hideGeneration = 0
    // Hands-free silence reminder: after this long without speech — and only
    // when the keyboard and mouse are idle too, so it never interrupts someone
    // editing — the pill switches to "Still listening…". Long on purpose:
    // most sessions should end before it ever appears.
    private static let silenceReminderAfter: TimeInterval = 30
    private static let inputIdleGrace: TimeInterval = 6
    private static let voiceLevel: Float = 0.1
    private var lastVoiceTime: TimeInterval = 0

    // Fires when the close button on the locked pill is clicked.
    var onStopHandsFree: (() -> Void)? {
        get { model.onStop }
        set { model.onStop = newValue }
    }

    // Settings drive the quick menu (mic, clean-up) and remember where the
    // user dragged the pill.
    var settings: SettingsStore? {
        get { model.settings }
        set { model.settings = newValue }
    }

    var levelsProvider: (() -> [PolishLevel])? {
        get { model.levelsProvider }
        set { model.levelsProvider = newValue }
    }

    // True while we set the frame ourselves, so the didMove observer only
    // records user drags.
    private var isRepositioning = false
    private var moveObserver: NSObjectProtocol?

    // Basic dictation (fallback engine) in use: the pill carries a small tag
    // so it's always visible when a session runs at reduced accuracy.
    var isBasic: Bool {
        get { model.isBasic }
        set { model.isBasic = newValue }
    }

    // `command: true` marks a command hold — same live meter, purple styling,
    // so "talking to the app" never looks like "typing into the document".
    func show(levelProvider: @escaping () -> Float, command: Bool = false) {
        model.mode = .recording
        model.hint = nil
        model.isLocked = false
        model.isCommand = command
        model.stillListening = false
        present()
        // While recording the pill takes mouse input so it can be dragged to
        // a better spot and right-clicked for the quick menu. The transient
        // states below stay click-through.
        panel?.ignoresMouseEvents = false
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            let level = levelProvider()
            Task { @MainActor in
                guard let self else { return }
                self.model.level = level
                self.updateStillListening(level: level)
            }
        }
    }

    // Hands-free lock engaged: keep the live meter, add the lock affordance.
    // Only the locked pill takes mouse input (for its close button) — everywhere
    // else the panel stays click-through so it can never swallow a stray click.
    func showLocked() {
        model.isLocked = true
        panel?.ignoresMouseEvents = false
        lastVoiceTime = ProcessInfo.processInfo.systemUptime
    }

    private func updateStillListening(level: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        if level > Self.voiceLevel { lastVoiceTime = now }
        guard model.isLocked, now - lastVoiceTime > Self.silenceReminderAfter else {
            model.stillListening = false
            return
        }
        // System-wide input idle: typing or mousing means the user is engaged,
        // not absent — hold the reminder back.
        let inputIdle = min(
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved))
        model.stillListening = inputIdle > Self.inputIdleGrace
    }

    // Brief note inside a live recording pill (e.g. mic switched) — the meter
    // comes right back; unlike showHint this never leaves recording mode.
    func showNotice(_ text: String) {
        guard model.mode == .recording else { return }
        model.notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.model.notice == text { self?.model.notice = nil }
        }
    }

    func showTranscribing(label: String? = nil) {
        levelTimer?.invalidate()
        model.mode = .transcribing
        model.isCommand = false
        model.transcribingLabel = label
        present()
        panel?.ignoresMouseEvents = true
    }

    // Command twin of showTranscribing: the model is thinking, not typing yet.
    func showWorking() {
        levelTimer?.invalidate()
        model.mode = .transcribing
        model.isCommand = true
        model.transcribingLabel = nil
        present()
        panel?.ignoresMouseEvents = true
    }

    func showHint(_ text: String) {
        levelTimer?.invalidate()
        model.mode = .hint
        model.hint = text
        present()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.model.mode == .hint { self?.hide() }
        }
    }

    func hide() {
        levelTimer?.invalidate()
        levelTimer = nil
        guard let panel else { return }
        panel.ignoresMouseEvents = true
        hideGeneration += 1
        let generation = hideGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hideGeneration == generation else { return }
                panel.orderOut(nil)
            }
        })
    }

    private func present() {
        hideGeneration += 1   // invalidate any in-flight hide completion
        let panel = ensurePanel()
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        model.onResetPosition = { [weak self] in
            guard let self else { return }
            self.settings?.indicatorPosition = nil
            if let panel = self.panel { self.position(panel) }
        }
        panel.contentView = NSHostingView(rootView: IndicatorView(model: model))
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordUserMove() }
        }
        self.panel = panel
        return panel
    }

    // A drag ended somewhere new — remember it as fractions of the screen's
    // visible frame so the spot survives resolution and screen changes.
    private func recordUserMove() {
        guard !isRepositioning, let panel, panel.isVisible,
              let screen = panel.screen ?? NSScreen.main else { return }
        let f = screen.visibleFrame
        let denomX = max(f.width - panel.frame.width, 1)
        let denomY = max(f.height - panel.frame.height, 1)
        settings?.indicatorPosition = CGPoint(x: (panel.frame.minX - f.minX) / denomX,
                                              y: (panel.frame.minY - f.minY) / denomY)
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let screen else { return }
        isRepositioning = true
        defer { isRepositioning = false }
        panel.setContentSize(NSSize(width: 280, height: 44))
        let f = screen.visibleFrame
        if let saved = settings?.indicatorPosition {
            let fx = min(max(saved.x, 0), 1)
            let fy = min(max(saved.y, 0), 1)
            panel.setFrameOrigin(NSPoint(x: f.minX + fx * (f.width - panel.frame.width),
                                         y: f.minY + fy * (f.height - panel.frame.height)))
            return
        }
        let x = f.midX - panel.frame.width / 2
        let y = f.minY + 96
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
final class IndicatorModel: ObservableObject {
    enum Mode { case recording, transcribing, hint }
    @Published var mode: Mode = .recording
    @Published var level: Float = 0
    @Published var hint: String?
    @Published var isLocked = false
    @Published var stillListening = false
    @Published var isBasic = false
    @Published var isCommand = false
    @Published var notice: String?
    // Overrides the "Typing…" caption (e.g. "Polishing…" while a rewrite runs).
    @Published var transcribingLabel: String?
    var onStop: (() -> Void)?
    var onResetPosition: (() -> Void)?
    var settings: SettingsStore?
    // Which clean-up levels the quick menu offers (Concise only where the
    // rewrite engine exists) — supplied by the controller.
    var levelsProvider: (() -> [PolishLevel])?
}

struct IndicatorView: View {
    @ObservedObject var model: IndicatorModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.mode {
            case .recording:
                // Hands-free trades the red mic for an orange one plus a lock —
                // a quiet "still listening" that users can discover on their own.
                // A command hold gets a purple mic: Aloud is listening for an
                // instruction, not taking dictation.
                Image(systemName: "mic.fill")
                    .foregroundStyle(model.isCommand ? Color.purple
                                     : model.isLocked ? Color.orange : Color.red)
                    .symbolEffect(.pulse, isActive: model.stillListening)
                // Reduced-accuracy session: same tag style as onboarding
                // badges, present in held and hands-free pills alike.
                if model.isBasic {
                    Text(loc("Basic"))
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .foregroundStyle(.orange)
                        .overlay(Capsule().strokeBorder(Color.orange.opacity(0.5), lineWidth: 0.5))
                }
                if let notice = model.notice {
                    Text(notice)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if model.stillListening {
                    Text(loc("Still listening…"))
                        .foregroundStyle(.orange)
                        .frame(width: 90)
                } else {
                    LevelMeter(level: model.level)
                        .frame(width: 90, height: 18)
                }
                if model.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.orange)
                    Button {
                        model.onStop?()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(loc("Stop — or press Esc"))
                }
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                Text(model.transcribingLabel ?? (model.isCommand ? loc("Working…") : loc("Typing…")))
                    .foregroundStyle(.secondary)
            case .hint:
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(model.hint ?? "")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(duration: 0.25), value: model.mode == .recording)
        .animation(.spring(duration: 0.25), value: model.isLocked)
        .animation(.spring(duration: 0.25), value: model.stillListening)
        .animation(.spring(duration: 0.25), value: model.notice)
        .contextMenu { quickMenu }
    }

    // Right-click quick menu: the settings people flip mid-dictation, without
    // a trip to the Settings window. Drag the pill itself to move it.
    @ViewBuilder
    private var quickMenu: some View {
        if let settings = model.settings {
            Picker(loc("Microphone"), selection: Binding(
                get: { settings.microphoneUID },
                set: { settings.microphoneUID = $0 })) {
                Text(loc("System default")).tag(nil as String?)
                ForEach(AudioDevices.inputDevices()) { d in
                    Text(d.name).tag(d.uid as String?)
                }
            }
            Picker(loc("Clean-up"), selection: Binding(
                get: { settings.polishLevel },
                set: { settings.polishLevel = $0 })) {
                ForEach(model.levelsProvider?() ?? PolishLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            Divider()
            Button(loc("Reset Position")) { model.onResetPosition?() }
        }
    }
}

// A row of bars that follow the live input level — system-toned, no custom drawing
// beyond simple rounded rectangles.
struct LevelMeter: View {
    var level: Float
    private let barCount = 12

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barActive(i) ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 3)
                    .frame(height: barHeight(i))
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }

    private func barActive(_ i: Int) -> Bool {
        Float(i) / Float(barCount) < level
    }

    private func barHeight(_ i: Int) -> CGFloat {
        // Gentle center-weighted profile so the meter reads as a waveform.
        let x = Double(i) / Double(barCount - 1)
        let profile = 0.4 + 0.6 * sin(x * .pi)
        return CGFloat(8 + 10 * profile)
    }
}
