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
    // Bumped by present() and hide() so a pending or in-flight hide can tell
    // whether a show snuck in behind it (hands-free is a cancel immediately
    // followed by a re-show) and must leave the panel alone.
    private var hideGeneration = 0
    // Same idea for hint auto-dismissal, so a second hint can't be cut short
    // by the first one's timer.
    private var hintGeneration = 0
    // Logically on screen: present() called, no hide committed yet.
    private var isShowing = false
    private var isFadingOut = false
    private var shownAt: TimeInterval = 0
    private static let fadeDuration: TimeInterval = 0.18
    // A pill that just appeared holds still this long before it may fade out.
    // Arming hands-free is a short tap (cancel → hide) followed by a second
    // press up to a double-tap window later (begin → show); without this floor
    // the pill blinks out and back in mid-gesture and reads as a glitch. Any
    // session long enough to be real has already outlived it.
    private static let minimumVisible: TimeInterval = 0.6
    // The window the pill floats in. Taller than the pill itself so the noise
    // badge can sit proud of its top corner without the window edge cutting
    // through it; the pill stays vertically centred, so the extra height is
    // invisible. Defined once because it is set in two places, and when those
    // two drifted apart the reposition quietly squashed the badge flat.
    static let panelSize = NSSize(width: 280, height: 80)
    // Hands-free silence reminder ("Still listening…", rule in SilenceReminder
    // below). These two track it when no speech detector is available: the
    // input level that counts as a voice, and when it was last cleared.
    private static let voiceLevel: Float = 0.1
    private var lastVoiceTime: TimeInterval = 0
    // When the session was locked.
    private var lockedAt: TimeInterval = 0

    // Seconds since the mic last heard actual speech, when a speech detector
    // is running. nil falls back to the input-level threshold below — which is
    // the reason this exists: a room with a fan, a café, or a nearby
    // conversation clears that threshold on its own, so the reminder that's
    // supposed to catch a session left running never fired anywhere noisy.
    var speechAgeProvider: (() -> TimeInterval?)?

    // Fires when the close button on the locked pill is clicked.
    var onStopHandsFree: (() -> Void)? {
        get { model.onStop }
        set { model.onStop = newValue }
    }

    // The noise-filtering badge on the pill: its state, and what a click does.
    var noiseReduction: Bool {
        get { model.noiseReduction }
        set { model.noiseReduction = newValue }
    }
    var onToggleNoiseReduction: (() -> Void)? {
        get { model.onToggleNoiseReduction }
        set { model.onToggleNoiseReduction = newValue }
    }
    // Rebuilding capture for a filter flip takes a moment. The badge shows a
    // spinner for that stretch instead of pretending the flip already
    // landed, and ignores presses until it has.
    var noiseBusy: Bool {
        get { model.noiseBusy }
        set { model.noiseBusy = newValue }
    }
    // Whether the audio route allows filtering at all (headphones as the
    // output make it unavailable). Off: the quick menu's toggle dims, and
    // the badge never shows — nothing may claim a filter that cannot run.
    var noiseReductionAvailable: Bool {
        get { model.noiseReductionAvailable }
        set { model.noiseReductionAvailable = newValue }
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
    func show(levelProvider: @escaping () -> Float,
              bandsProvider: (() -> [Float])? = nil,
              command: Bool = false) {
        model.mode = .recording
        model.hint = nil
        model.isLocked = false
        model.isCommand = command
        model.stillListening = false
        model.notice = nil   // never carry a previous session's note into this one
        model.level = 0
        model.bands = SpectrumAnalyzer.silent
        present()
        // While recording the pill takes mouse input so it can be dragged to
        // a better spot and right-clicked for the quick menu. The transient
        // states below stay click-through.
        panel?.ignoresMouseEvents = false
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            let level = levelProvider()
            // No spectrum available (a caller that only has a level): every bar
            // follows the one number, which is the old meter's behaviour.
            let bands = bandsProvider?() ?? [Float](repeating: level, count: SpectrumAnalyzer.bandCount)
            Task { @MainActor in
                guard let self else { return }
                // Fast attack, slow release: raw RMS jitters frame to frame and
                // a bare threshold made the leading bars strobe. Rising edges
                // stay instant so the meter still feels live.
                self.model.level = level > self.model.level
                    ? level
                    : self.model.level + (level - self.model.level) * 0.25
                // Same curve per band — audio arrives in chunks slower than
                // this timer, so without it the bars would step, not move.
                self.model.bands = Self.smooth(self.model.bands, toward: bands)
                self.updateStillListening(level: level)
            }
        }
    }

    private static func smooth(_ current: [Float], toward target: [Float]) -> [Float] {
        guard current.count == target.count else { return target }
        return zip(current, target).map { now, next in
            next > now ? next : now + (next - now) * 0.28
        }
    }

    // Whether the pill currently wears the hands-free lock. The controller
    // reads this across its async session start: a lock that arrived while
    // the engine was still spinning up must survive the flip from "Getting
    // ready…" to the live meter (show() resets it for fresh sessions).
    var isHandsFreeLocked: Bool { model.isLocked }

    // Hands-free lock engaged: keep the live meter, add the lock affordance.
    // Only the locked pill takes mouse input (for its close button) — everywhere
    // else the panel stays click-through so it can never swallow a stray click.
    func showLocked() {
        model.isLocked = true
        panel?.ignoresMouseEvents = false
        lastVoiceTime = ProcessInfo.processInfo.systemUptime
        lockedAt = lastVoiceTime
    }

    // The reminder latches: it appears once the session has been silent long
    // enough while the user is away from the keyboard, and then only speech
    // takes it back down. Recomputing it every frame let a single mouse twitch
    // swap the caption for the meter and back — a 30 Hz flicker on an otherwise
    // static pill.
    private func updateStillListening(level: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        let silentFor: TimeInterval
        if let age = speechAgeProvider?() {
            silentFor = age
        } else {
            if level > Self.voiceLevel { lastVoiceTime = now }
            silentFor = now - lastVoiceTime
        }
        let wasShowing = model.stillListening
        model.stillListening = SilenceReminder.next(
            showing: wasShowing,
            silentFor: silentFor,
            lockedFor: now - lockedAt,
            isLocked: model.isLocked,
            // System-wide input idle: typing or mousing means the user is
            // engaged, not absent — hold the reminder back. Read lazily; it's
            // three syscalls that only matter at the moment of the decision.
            inputIdle: {
                min(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown),
                    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown),
                    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved))
            })
        // The reminder exists because the user's eyes are elsewhere — a
        // pill quietly swapping its caption may never be seen at all. One
        // gentle sound at the moment it latches; the latch itself keeps it
        // from repeating until speech resets it.
        if model.stillListening, !wasShowing { onStillListening?() }
    }

    // Fires once each time the still-listening reminder appears.
    var onStillListening: (() -> Void)?

    // The reminder, on demand — only --indicator-demo calls this; the real
    // one waits out thirty silent seconds that a screenshot script can't.
    // The level timer stops too: its per-frame recompute would put the
    // meter straight back.
    func demoStillListening() {
        levelTimer?.invalidate()
        levelTimer = nil
        model.stillListening = true
    }

    // Timings live on the panel; the rule itself is here so it can be tested
    // without an AppKit window or a 30 Hz timer.
    enum SilenceReminder {
        static let showAfter: TimeInterval = 30
        static let inputIdleGrace: TimeInterval = 6
        static let recentSpeechWindow: TimeInterval = 0.5

        // `silentFor` is seconds since speech, `lockedFor` seconds since the
        // session was locked — the reminder waits out both, so locking a
        // session that had already gone quiet still gets its full thirty
        // seconds rather than an instant nudge.
        static func next(showing: Bool,
                         silentFor: TimeInterval,
                         lockedFor: TimeInterval,
                         isLocked: Bool,
                         inputIdle: () -> TimeInterval) -> Bool {
            guard silentFor >= recentSpeechWindow, isLocked else { return false }
            guard !showing else { return true }
            let quietFor = min(silentFor, lockedFor)
            guard quietFor > showAfter else { return false }
            return inputIdle() > inputIdleGrace
        }
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
        levelTimer = nil
        model.mode = .hint
        model.hint = text
        model.notice = nil
        model.stillListening = false
        present()
        panel?.ignoresMouseEvents = true
        hintGeneration += 1
        let generation = hintGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, self.hintGeneration == generation, self.model.mode == .hint else { return }
            self.hide()
        }
    }

    func hide() {
        levelTimer?.invalidate()
        levelTimer = nil
        model.level = 0   // let the meter drain rather than freeze mid-fade
        model.bands = SpectrumAnalyzer.silent
        guard let panel, isShowing else { return }
        isShowing = false
        panel.ignoresMouseEvents = true
        hideGeneration += 1
        let generation = hideGeneration
        let elapsed = ProcessInfo.processInfo.systemUptime - shownAt
        let delay = max(0, Self.minimumVisible - elapsed)
        guard delay > 0 else { return fadeOut(generation) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.fadeOut(generation)
        }
    }

    private func fadeOut(_ generation: Int) {
        guard hideGeneration == generation, let panel, panel.isVisible else { return }
        isFadingOut = true
        // The drain plays inside the alpha fade's window; ease-in mirrors the
        // entrance the way the badge's exit mirrors its arrival.
        withAnimation(.easeIn(duration: Self.fadeDuration)) { model.revealed = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hideGeneration == generation else { return }
                self.isFadingOut = false
                panel.orderOut(nil)
                self.model.revealed = true   // rest state for the next show
            }
        })
    }

    private func present() {
        hideGeneration += 1   // cancel any pending or in-flight hide
        let panel = ensurePanel()
        if !isShowing {
            isShowing = true
            shownAt = ProcessInfo.processInfo.systemUptime
        }
        // Already on screen: only the pill's contents changed. Re-running the
        // fade (or re-deriving the position, which follows the mouse's screen)
        // is what made every state change blink and occasionally jump displays.
        guard !panel.isVisible else {
            if isFadingOut || panel.alphaValue < 1 { fadeIn(panel) }
            // A show that caught an exit mid-drain springs the pill back up
            // from wherever the drain had it.
            if !model.revealed { reveal() }
            return
        }
        position(panel)
        panel.alphaValue = 0
        // Start shrunk while still invisible, then bloom on the next turn —
        // same-turn would render the resting state straight away.
        model.revealed = false
        panel.orderFrontRegardless()
        fadeIn(panel)
        DispatchQueue.main.async { [weak self] in self?.reveal() }
    }

    private func reveal() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) { model.revealed = true }
    }

    // Ramps from wherever alpha is now, so catching a fade-out mid-flight
    // reverses it instead of restarting from invisible.
    private func fadeIn(_ panel: NSPanel) {
        isFadingOut = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.panelSize.width,
                                                height: Self.panelSize.height),
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
        panel.setContentSize(Self.panelSize)
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
    enum Mode: Equatable { case recording, transcribing, hint }
    @Published var mode: Mode = .recording
    @Published var level: Float = 0
    // Per-band levels (0…1), low frequency first — what the meter draws.
    @Published var bands: [Float] = SpectrumAnalyzer.silent
    @Published var hint: String?
    @Published var isLocked = false
    @Published var stillListening = false
    @Published var isBasic = false
    @Published var isCommand = false
    @Published var notice: String?
    // Overrides the "Typing…" caption (e.g. "Polishing…" while a rewrite runs).
    @Published var transcribingLabel: String?
    // Whether background noise is being filtered right now. Mirrored here
    // rather than read from settings so the pill redraws the moment it changes.
    @Published var noiseReduction = false
    // A filter flip's capture rebuild is in flight; the badge spins.
    @Published var noiseBusy = false
    // Whether the route allows filtering at all; gates the quick menu toggle.
    @Published var noiseReductionAvailable = true
    // Entrance/exit: false renders the pill shrunk and dropped, true at rest.
    // The panel drives it inside withAnimation so an interrupted exit springs
    // back from wherever it was, and leaves it un-animated when the user has
    // turned the effect off.
    @Published var revealed = true
    var onStop: (() -> Void)?
    var onToggleNoiseReduction: (() -> Void)?
    var onResetPosition: (() -> Void)?
    var settings: SettingsStore?
    // Which clean-up levels the quick menu offers (Concise only where the
    // rewrite engine exists) — supplied by the controller.
    var levelsProvider: (() -> [PolishLevel])?
}

struct IndicatorView: View {
    @ObservedObject var model: IndicatorModel
    // The pointer is over the pill. Everything optional on it appears on this,
    // so the resting state stays a mic and a meter.
    @State private var hovering = false
    // 0 → 1: how far the border, and separately the tint, have spread out
    // from the badge. Two values because the outline should arrive first and
    // the colour fill in behind it — a line drawn, then the wash. Driven
    // explicitly so turning the feature off plays the same journey backwards
    // before the badge goes grey.
    @State private var borderReveal: CGFloat = 0
    @State private var tintReveal: CGFloat = 0
    // The badge exists only while filtering is on. `lit` is its colour —
    // Aloud blue while the feature is, grey for the moment after it is
    // switched off, so the badge is seen to change before it leaves.
    @State private var badgeVisible = false
    @State private var badgeLit = false
    @State private var badgeFadeOut: Task<Void, Never>?
    // Bumped on every noiseReduction change. A rapid re-toggle starts a new
    // generation before the previous one's fade-out completion fires, so that
    // stale completion can tell it no longer describes the current state and
    // bail instead of forcing the badge back off underneath the new state.
    @State private var noiseGeneration = 0

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
                        // The pill is a fixed width; a long note shrinks a
                        // little rather than being cut off mid-word.
                        .minimumScaleFactor(0.8)
                } else if model.stillListening {
                    StillListeningCaption()
                        .frame(width: 90)
                } else {
                    SpectrumMeter(bands: model.bands, tint: meterTint)
                        .frame(width: 90, height: 18)
                }
                if model.isLocked {
                    // No padlock: the close button is the thing that says this
                    // session is running on its own and has to be ended, and
                    // saying it twice in a row that narrow just crowds it.
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
                    .minimumScaleFactor(0.8)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                // Filtering on: the pill takes Aloud's own blue, as a tint
                // through the material and a border around it. Both are
                // revealed by a circle opening out from the badge, so the
                // colour arrives from the thing that was just pressed and
                // meets itself at the far end.
                Capsule().fill(Color.aloud.opacity(0.22))
                    .mask { revealMask(tintReveal) }
                Capsule().strokeBorder(Color.aloud.opacity(0.85), lineWidth: 1.5)
                    .mask { revealMask(borderReveal) }
            }
        }
        .overlay(Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        // The menu belongs to the pill, not to the badge sitting on its
        // corner: attached out here it covers the badge too, and every click
        // meant for the badge opens the menu instead. The badge goes on top,
        // after this, so it gets its own clicks in every mode.
        .contextMenu { quickMenu }
        .overlay(alignment: .topTrailing) { noiseBadge.offset(x: 8, y: -8) }
        .onAppear {
            // A pill that opens with filtering already on shows it, rather
            // than animating something the user didn't just do.
            let on: CGFloat = model.noiseReduction ? 1 : 0
            borderReveal = on
            tintReveal = on
            badgeVisible = model.noiseReduction
            badgeLit = model.noiseReduction
        }
        .onChange(of: model.noiseReduction) { _, on in
            badgeFadeOut?.cancel()
            badgeFadeOut = nil
            noiseGeneration += 1
            let generation = noiseGeneration
            if on {
                // The badge appears and the outline runs round together, in
                // the same breath as the press; the colour follows behind and
                // settles a moment later.
                withAnimation(.easeOut(duration: 0.3)) {
                    badgeVisible = true
                    badgeLit = true
                    borderReveal = 1
                }
                withAnimation(.easeOut(duration: 0.6)) { tintReveal = 1 }
            } else {
                withAnimation(.easeIn(duration: 0.3)) { borderReveal = 0 }
                // The badge is the last thing to change, the way it was the
                // first: only once the colour has drained all the way home
                // does it go grey, hold long enough to be seen doing it, and
                // then leave.
                withAnimation(.easeIn(duration: 0.6), completionCriteria: .removed) {
                    tintReveal = 0
                } completion: {
                    // A re-toggle before this fires started a fresh
                    // generation above; a stale completion must not force
                    // the badge back off underneath the state it since moved to.
                    guard generation == noiseGeneration else { return }
                    badgeLit = false
                    badgeFadeOut = Task {
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        guard !Task.isCancelled, generation == noiseGeneration else { return }
                        withAnimation(.easeOut(duration: 0.25)) { badgeVisible = false }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(duration: 0.25), value: model.mode)
        .animation(.spring(duration: 0.25), value: model.isLocked)
        .animation(.spring(duration: 0.25), value: model.stillListening)
        .animation(.spring(duration: 0.25), value: model.notice)
        // The pill grows a touch under the pointer and settles back when it
        // leaves — enough to say "this is a thing you can touch" without
        // becoming a moving target while someone is talking.
        .scaleEffect(hovering && model.mode == .recording ? 1.03 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.noiseReduction)
        // Entrance/exit, in the badge's family: the pill blooms up into place
        // and drains back down. Purely a render of `revealed` — the panel
        // decides when and whether it animates.
        .scaleEffect(model.revealed ? 1 : 0.72)
        .offset(y: model.revealed ? 0 : 12)
        .onHover { hovering = $0 }
    }

    // A circle centred on the badge, opening out until it covers the whole
    // pill. Masking the tint and the border with it makes the colour appear to
    // run around the capsule in both directions at once and close on the
    // opposite side — one value to animate, and it reverses for free.
    private func revealMask(_ progress: CGFloat) -> some View {
        GeometryReader { geo in
            let reach = 2 * sqrt(geo.size.width * geo.size.width
                                 + geo.size.height * geo.size.height)
            Circle()
                .frame(width: reach * progress, height: reach * progress)
                .position(x: geo.size.width - 4, y: 4)   // the badge's centre
        }
    }

    // Background-noise filtering, as a badge on the pill.
    //
    // A badge rather than another item in the row, because the row already
    // reads left to right as mode → am I being heard → end this session, and
    // this is none of those: it is a standing fact about how the microphone is
    // being listened to. Sitting proud of the top-right corner, the way a
    // count sits on an app icon, it says so without taking a place in that
    // sentence or crowding the meter.
    //
    // Filled and tinted when filtering is on, and always visible then — the
    // point of it is that you can see the state at a glance. Off, it waits for
    // the pointer and then fades in hollow: same corner, same shape, obviously
    // the same control, obviously not doing anything. Either way one click
    // flips it.
    @ViewBuilder
    private var noiseBadge: some View {
        if model.mode == .recording, badgeVisible {
            Button {
                guard !model.noiseBusy else { return }
                model.onToggleNoiseReduction?()
            } label: {
                Group {
                    if model.noiseBusy {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(badgeLit ? .white : nil)
                    } else {
                        Image(systemName: "waveform.badge.minus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(badgeLit ? AnyShapeStyle(.white)
                                                      : AnyShapeStyle(.secondary))
                    }
                }
                    .frame(width: 24, height: 24)
                    .background {
                        // Off, the pill's own ultra-thin material would make
                        // the badge disappear into it — a heavier backdrop is
                        // what makes it read as a separate, pressable thing.
                        Circle().fill(badgeLit ? AnyShapeStyle(Color.aloud)
                                               : AnyShapeStyle(.regularMaterial))
                    }
                    // A hairline in the window's own backdrop, so the badge
                    // reads as sitting on top of the pill rather than punched
                    // out of it.
                    .overlay(Circle().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .help(loc("Background noise is being filtered — click to stop"))
            // Scale only, no opacity: the badge's own background is a
            // translucent material off, solid on — fading its alpha in on top
            // of the tint/border reveal sweeping in behind it let that sweep
            // show through the badge itself, like a seam cutting across it.
            // Fully opaque throughout, it just grows in instead.
            .transition(.scale(scale: 0.4))
        }
    }

    // The meter agrees with the mic glyph in the two modes that have a colour
    // of their own; plain dictation keeps the accent colour, which is quieter
    // next to a red mic than a second red thing would be.
    private var meterTint: Color {
        model.isCommand ? .purple : model.isLocked ? .orange : .accentColor
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
            // The same switch the badge is, in words. During a held dictation
            // the badge is a small target to hit one-handed, and this menu is
            // already where the other capture settings live.
            Toggle(loc("Reduce background noise"), isOn: Binding(
                get: { model.noiseReduction },
                set: { _ in model.onToggleNoiseReduction?() }))
                .disabled(!model.noiseReductionAvailable)
            Divider()
            Button(loc("Reset Position")) { model.onResetPosition?() }
        }
    }
}

// The hands-free silence reminder, sized to hold the meter's slot on one
// line, with a soft shine sweeping through the glyphs every few seconds —
// for the user glancing back at a screen they stopped watching, a caption
// that moves is found faster than one that sits still.
private struct StillListeningCaption: View {
    // 0 → 1 is one sweep; the gradient band spans well past the text on both
    // sides, so most of each cycle it is off the glyphs entirely — the pause
    // between shimmers comes free, no timer needed.
    @State private var phase: CGFloat = 0

    var body: some View {
        Text(loc("Still listening…"))
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(.orange)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.85), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.55)
                        .offset(x: phase * geo.size.width * 2.6 - geo.size.width * 0.8)
                }
                .mask(
                    Text(loc("Still listening…"))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                )
                .allowsHitTesting(false)
            }
            .onAppear {
                phase = 0
                withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

// One bar per frequency band, low on the left, each rising with the energy the
// mic is picking up there. Silence rests as a row of dots rather than an empty
// gap, so the meter always says "the mic is on" even when nobody is talking.
// System colours, rounded rectangles, no markings — nothing to read, only
// something to recognise.
struct SpectrumMeter: View {
    var bands: [Float]
    var tint: Color

    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 3
    private let restHeight: CGFloat = 3
    private let maxHeight: CGFloat = 18

    var body: some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(Array(bands.enumerated()), id: \.offset) { i, value in
                let v = CGFloat(min(max(value, 0), 1))
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(tint.opacity(0.4 + 0.6 * Double(v)))
                    .frame(width: barWidth, height: restHeight + (maxHeight - restHeight) * v)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .bottom)
        // Interpolates between audio frames, which land slower than the display.
        .animation(.linear(duration: 0.05), value: bands)
    }
}
