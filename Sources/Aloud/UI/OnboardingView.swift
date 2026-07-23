import Network
import SwiftUI

// First-run flow, Setup Assistant style: one instruction per screen, a single
// primary button, progress dots. Screens for permissions poll live status and
// auto-advance the moment the user grants access in System Settings.
struct OnboardingView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var settings: SettingsStore
    let onFinished: () -> Void

    init(controller: DictationController, onFinished: @escaping () -> Void) {
        self.controller = controller
        _settings = ObservedObject(wrappedValue: controller.settings)
        self.onFinished = onFinished
    }

    enum Step: Int, CaseIterable {
        case welcome, microphone, accessibility, model, liveTyping, tryIt
    }

    @State private var step: Step = .welcome
    @State private var micStatus = Permissions.microphone
    @State private var axStatus = Permissions.accessibility
    @State private var micDeniedOnce = false
    @State private var tryItDone = false
    @State private var isOnline = true
    @State private var networkMonitor = NWPathMonitor()

    private let poll = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)
            content
                .frame(maxWidth: 420)
                .padding(.horizontal, 40)
            Spacer()
            dots
                .padding(.bottom, 28)
        }
        .frame(width: 560, height: 460)
        .background(.background)
        .overlay(alignment: .bottomLeading) {
            if step != .welcome {
                Button {
                    retreat()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(OnboardingButtonStyle(minWidth: 0))
                .padding(.leading, 20)
                .padding(.bottom, 20)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if step == .liveTyping {
                Button("Next") { advance() }
                    .buttonStyle(OnboardingButtonStyle(prominent: true, minWidth: 60))
                    .keyboardShortcut(.defaultAction)
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
            }
        }
        .onAppear {
            // Start the model download quietly right away so it's finished (or
            // well underway) by the time the user reaches the model screen.
            Task { await controller.prepareModel() }
            // Watch connectivity for the model step: no network is a normal
            // first-run situation, and the download should resume by itself.
            networkMonitor.pathUpdateHandler = { path in
                let nowOnline = path.status == .satisfied
                Task { @MainActor in
                    let cameBack = nowOnline && !isOnline
                    isOnline = nowOnline
                    if cameBack {
                        switch controller.transcriberState {
                        case .modelMissing, .failed: await controller.prepareModel()
                        default: break
                        }
                    }
                }
            }
            networkMonitor.start(queue: .global(qos: .utility))
        }
        .onReceive(poll) { _ in
            micStatus = Permissions.microphone
            axStatus = Permissions.accessibility
            // Auto-advance when a screen's requirement is met. Granting
            // happened in a system dialog or System Settings, and macOS
            // doesn't hand focus back to us — reclaim it so the flow visibly
            // continues instead of sitting behind whatever has focus.
            if step == .microphone, micStatus == .granted { advance(); reclaimFocus() }
            if step == .accessibility, axStatus == .granted { advance(); reclaimFocus() }
            if step == .model, controller.transcriberState == .ready { advance() }
            if step == .tryIt, !controller.lastTranscription.isEmpty { tryItDone = true }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .microphone: microphone
        case .accessibility: accessibility
        case .model: model
        case .liveTyping: liveTyping
        case .tryIt: tryIt
        }
    }

    // MARK: screens

    private var welcome: some View {
        screen(symbol: "waveform",
               title: "Welcome to Aloud",
               message: "Speak instead of typing — your words appear wherever your cursor is. Everything happens on your Mac; nothing you say ever leaves it.") {
            VStack(spacing: 16) {
                VStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Text("Hold")
                        HotkeyRecorderView(hotkey: settings.hotkey) { controller.updateHotkey($0) }
                        Text("· speak · let go")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Text("That’s your talk key. \(Hotkey.default.displayName) works great — or click it to pick your own.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                primaryButton("Continue") { advance() }
            }
        }
    }

    private var microphone: some View {
        screen(symbol: "mic",
               title: "Allow the Microphone",
               message: "Aloud needs the microphone to hear you while you hold the dictation key. Audio is processed on this Mac and never uploaded.") {
            VStack(spacing: 12) {
                if micStatus == .denied {
                    Text("Microphone access is turned off. Turn it on for Aloud in System Settings, then come back — this screen will move on automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    primaryButton("Open System Settings") { Permissions.openMicrophoneSettings() }
                } else {
                    primaryButton("Allow Microphone") {
                        Permissions.requestMicrophone { granted in
                            micStatus = Permissions.microphone
                            if granted { advance() } else { micDeniedOnce = true }
                        }
                    }
                }
            }
        }
    }

    private var accessibility: some View {
        screen(symbol: "keyboard",
               title: "Let Aloud Type for You",
               message: "This lets your talk key work in every app, and lets Aloud type the words where your cursor is. macOS calls this “Accessibility” access.") {
            VStack(spacing: 12) {
                Text("In System Settings, turn on the switch next to Aloud under Privacy & Security → Accessibility. This screen will move on automatically once it's on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                primaryButton("Open System Settings") {
                    Permissions.openAccessibilitySettings()
                }
            }
        }
    }

    // The download already started in the background when onboarding opened,
    // so this screen usually just shows progress and auto-advances when ready.
    private var model: some View {
        screen(symbol: "arrow.down.circle",
               title: "Setting Up Your Voice",
               message: "Aloud is downloading its voice recognition — this happens once (about 500 MB). After this, dictation works completely offline, forever.") {
            VStack(spacing: 14) {
                switch controller.transcriberState {
                case .modelMissing where !isOnline, .failed where !isOnline:
                    Label("No internet connection", systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                    Text("Aloud needs the internet once, for this download. This screen will continue automatically when you're back online.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                case .modelMissing:
                    primaryButton("Download") {
                        Task { await controller.prepareModel() }
                    }
                case .downloading(let progress):
                    ProgressView(value: progress)
                        .frame(width: 260)
                    Text("\(Int(progress * 100))% — you can keep using your Mac")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .loading:
                    ProgressView()
                    Text("Getting things ready… (first time takes a few seconds)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .ready:
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    primaryButton("Continue") { advance() }
                case .failed:
                    Text("The download didn’t finish. Check your internet connection and try again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    primaryButton("Try Again") {
                        Task { await controller.prepareModel() }
                    }
                }
            }
        }
    }

    private var liveTyping: some View {
        screen(symbol: "text.cursor",
               title: "How Should Words Appear?",
               message: "You can change this any time in Settings.") {
            HStack(spacing: 12) {
                choiceCard(symbol: "text.cursor",
                           title: "Live",
                           badge: "Experimental",
                           caption: "Words appear as you say them and settle as Aloud hears more.",
                           selected: settings.liveTyping) {
                    settings.liveTyping = true
                }
                choiceCard(symbol: "text.insert",
                           title: "All at once",
                           caption: "Everything is typed the moment you let go of the key.",
                           selected: !settings.liveTyping) {
                    settings.liveTyping = false
                }
            }
            .animation(.spring(duration: 0.25), value: settings.liveTyping)
        }
    }

    // Flat, theme-safe buttons: the system's large bordered styles render a
// glossy light bezel with dark text no matter the appearance, which reads
// broken in dark mode. Accent fill for the one main action per screen,
// quiet fill for everything else.
private struct OnboardingButtonStyle: ButtonStyle {
    var prominent = false
    var minWidth: CGFloat = 160

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(prominent ? .semibold : .regular))
            .frame(minWidth: minWidth)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.7)),
                        in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

// A radio-style option card: exactly one is selected, shown by the accent
    // border, tinted fill, and corner checkmark.
    private func choiceCard(symbol: String, title: String, badge: String? = nil, caption: String,
                            selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(height: 30)
                HStack(spacing: 5) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    if let badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .foregroundStyle(.orange)
                            .overlay(Capsule().strokeBorder(Color.orange.opacity(0.5), lineWidth: 0.5))
                    }
                }
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 172, height: 138, alignment: .top)
            .background(selected ? Color.accentColor.opacity(0.1) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: selected ? 2 : 1)
            )
            .overlay(alignment: .topTrailing) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .padding(6)
                    .opacity(selected ? 1 : 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var tryIt: some View {
        screen(symbol: "quote.bubble",
               title: "Try It",
               message: "Click the box below, hold \(controller.settings.hotkey.displayName) while you say something, then let go.") {
            VStack(spacing: 16) {
                TextField("Your words will appear here", text: .constant(controller.lastTranscription))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                if tryItDone {
                    Label("That’s it — you’re set", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                (Text("Aloud lives in your menu bar — the ")
                 + Text(Image(systemName: "waveform"))
                 + Text(" icon at the top of your screen."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Tip: double-press \(controller.settings.hotkey.displayName) to keep listening hands-free — Esc finishes. You can turn this off in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                if tryItDone {
                    primaryButton("Done") { onFinished() }
                } else {
                    secondaryButton("Skip for now") { onFinished() }
                }
            }
        }
    }

    // MARK: chrome

    private func screen(symbol: String, title: String, message: String,
                        @ViewBuilder actions: () -> some View) -> some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor)
                .frame(height: 56)
            Text(title)
                .font(.title.weight(.semibold))
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions()
                .padding(.top, 6)
        }
    }

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(OnboardingButtonStyle(prominent: true))
            .keyboardShortcut(.defaultAction)
    }

    // Same size and shape as the primary button, quieter fill — unmistakably
    // clickable, unmistakably not the main path.
    private func secondaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(OnboardingButtonStyle())
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Circle()
                    .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
    }

    // Skip steps that are already satisfied, so reopening setup (or a re-grant
    // in System Settings) never replays screens the user has completed.
    private func advance() {
        var raw = step.rawValue + 1
        while let candidate = Step(rawValue: raw), isSatisfied(candidate) { raw += 1 }
        guard let next = Step(rawValue: raw) else { return }
        if next == .tryIt { _ = controller.startListening() }
        withAnimation(.spring(duration: 0.3)) { step = next }
    }

    private func reclaimFocus() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.title == "Welcome to Aloud" }?.makeKeyAndOrderFront(nil)
    }

    // Mirror of advance(): step backwards, skipping steps that are already
    // satisfied (the poll would instantly bounce the user forward off them).
    private func retreat() {
        var raw = step.rawValue - 1
        while let candidate = Step(rawValue: raw), isSatisfied(candidate) { raw -= 1 }
        guard let prev = Step(rawValue: raw) else { return }
        withAnimation(.spring(duration: 0.3)) { step = prev }
    }

    private func isSatisfied(_ s: Step) -> Bool {
        switch s {
        case .microphone: return Permissions.microphone == .granted
        case .accessibility: return Permissions.accessibility == .granted
        case .model: return controller.transcriberState == .ready
        case .welcome, .liveTyping, .tryIt: return false
        }
    }
}
