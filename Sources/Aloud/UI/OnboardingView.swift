import Network
import SwiftUI

// First-run flow: four screens, one job each — say what Aloud is, collect the
// two permissions it can't work without, get the voice model down, prove it
// works. Screens that wait on something (permissions, the download) poll and
// advance themselves the moment the requirement is met.
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
        case welcome, access, voice, tryIt, features

        // Harness hook: ALOUD_ONBOARDING_STEP=tryIt opens the flow on a later
        // screen so a screen can be inspected without clicking through.
        static var initial: Step {
            switch ProcessInfo.processInfo.environment["ALOUD_ONBOARDING_STEP"] {
            case "access": return .access
            case "voice": return .voice
            case "tryIt": return .tryIt
            case "features": return .features
            default: return .welcome
            }
        }
    }

    @State private var step: Step = .initial
    @State private var micStatus = Permissions.microphone
    @State private var axStatus = Permissions.accessibility
    @State private var tryItDone = false
    @State private var isOnline = true
    @State private var networkMonitor = NWPathMonitor()
    @State private var startingBasic = false
    @State private var basicUnavailable = false
    @State private var openedAccessibility = false
    // Which feature tile has its explanation open (one at a time).
    @State private var openFeature: String?

    private let poll = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)
            content
                .frame(maxWidth: 430)
                .padding(.horizontal, 40)
                .id(step)
                .transition(.opacity)
            Spacer()
            dots
                .padding(.bottom, 28)
        }
        .frame(width: 560, height: 470)
        .background(.background)
        .overlay(alignment: .bottomLeading) {
            if step != .welcome {
                Button {
                    retreat()
                } label: {
                    Label(loc("Back"), systemImage: "chevron.left")
                }
                .buttonStyle(OnboardingButtonStyle(minWidth: 0))
                .padding(.leading, 20)
                .padding(.bottom, 20)
            }
        }
        .onAppear {
            // Start the model download quietly right away so it's finished (or
            // well underway) by the time the user reaches the voice screen.
            Task { await controller.prepareModel() }
            // Watch connectivity for the voice screen: no network is a normal
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
            if step == .access, Permissions.allGranted { advance(); reclaimFocus() }
            if step == .voice, controller.transcriberState == .ready { advance() }
            if step == .tryIt, !controller.lastTranscription.isEmpty { tryItDone = true }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .access: access
        case .voice: voice
        case .tryIt: tryIt
        case .features: features
        }
    }

    // MARK: screens

    private var welcome: some View {
        screen(symbol: "waveform",
               title: loc("Welcome to Aloud"),
               message: loc("Speak instead of typing. Your words land wherever the cursor is, and nothing you say leaves this Mac.")) {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Text(loc("Hold"))
                        HotkeyRecorderView(hotkey: settings.hotkey) { controller.updateHotkey($0) }
                        Text(loc("· speak · let go"))
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Text(loc("Click the key to pick a different one."))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                primaryButton(loc("Continue")) { advance() }
            }
        }
    }

    // Both permissions on one screen: the user sees the whole ask at once and
    // watches it complete, instead of granting one and meeting a surprise.
    private var access: some View {
        screen(symbol: "lock.open",
               title: loc("Let Aloud Hear and Type"),
               message: loc("macOS guards both of these. Aloud needs them to work.")) {
            VStack(spacing: 12) {
                VStack(spacing: 0) {
                    accessRow(symbol: "mic",
                              title: loc("Microphone"),
                              detail: loc("Hears you while you hold the key."),
                              granted: micStatus == .granted,
                              actionLabel: micStatus == .denied ? loc("Open Settings") : loc("Allow")) {
                        if micStatus == .denied {
                            Permissions.openMicrophoneSettings()
                        } else {
                            Permissions.requestMicrophone { _ in micStatus = Permissions.microphone }
                        }
                    }
                    Divider().padding(.leading, 46)
                    accessRow(symbol: "keyboard",
                              title: loc("Accessibility"),
                              detail: loc("Types your words, and makes the key work in every app."),
                              granted: axStatus == .granted,
                              actionLabel: loc("Open Settings")) {
                        openedAccessibility = true
                        Permissions.openAccessibilitySettings()
                    }
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))

                if axStatus != .granted {
                    // After an update macOS often keeps a stale entry: the
                    // switch reads on while the app isn't actually trusted.
                    // Once they've been over there and it still hasn't taken,
                    // that's the likely reason — say so.
                    Text(openedAccessibility
                         ? loc("Switch already on? Turn it off and on again — macOS keeps a stale entry after an update.")
                         : loc("In System Settings, turn on the switch next to Aloud. This screen continues on its own."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func accessRow(symbol: String, title: String, detail: String,
                           granted: Bool, actionLabel: String,
                           action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(granted ? Color.green : Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.green)
                    .accessibilityLabel(loc("Allowed"))
            } else {
                // Fixed width so the two rows' buttons share an edge rather
                // than ending wherever their label happens to stop.
                Button(actionLabel, action: action)
                    .buttonStyle(OnboardingButtonStyle(minWidth: 100))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 54)
    }

    // The download already started in the background when onboarding opened,
    // so this screen usually just shows progress and auto-advances when ready.
    private var voice: some View {
        screen(symbol: "arrow.down.circle",
               title: loc("Setting Up Voice Recognition"),
               message: loc("A one-time download, about 500 MB. After this, dictation works offline.")) {
            VStack(spacing: 14) {
                switch controller.transcriberState {
                case .modelMissing where !isOnline, .failed where !isOnline:
                    Label(loc("No internet connection"), systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                    Text(loc("This screen continues on its own once you're back online."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    basicDictationOption
                case .modelMissing:
                    primaryButton(loc("Download")) {
                        Task { await controller.prepareModel() }
                    }
                case .downloading(let progress):
                    ProgressView(value: progress)
                        .frame(width: 260)
                    Text(loc("%ld%% — you can keep using your Mac", Int(progress * 100)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    basicDictationOption
                case .loading:
                    ProgressView()
                    Text(loc("Almost ready…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .ready:
                    Label(loc("Ready"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    primaryButton(loc("Continue")) { advance() }
                case .failed:
                    Text(loc("The download didn’t finish. Check your internet connection and try again."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    primaryButton(loc("Try Again")) {
                        Task { await controller.prepareModel() }
                    }
                    basicDictationOption
                }
            }
        }
    }

    // "Skip the wait" escape hatch on the download screen: start dictating now
    // with reduced accuracy, upgrade silently when the download completes.
    @ViewBuilder
    private var basicDictationOption: some View {
        if controller.fallbackAvailable {
            VStack(spacing: 8) {
                Divider().frame(width: 200).padding(.vertical, 2)
                if startingBasic {
                    ProgressView().controlSize(.small)
                } else {
                    secondaryButton(loc("Start Now with Basic Dictation")) {
                        startingBasic = true
                        basicUnavailable = false
                        Task {
                            let ok = await controller.activateFallback(interactive: true)
                            startingBasic = false
                            // The 0.8 s poll also advances on .ready — only
                            // advance if it hasn't beaten us to it.
                            if ok { if step == .voice { advance() } } else { basicUnavailable = true }
                        }
                    }
                }
                Text(basicUnavailable
                     ? loc("Basic dictation isn’t available right now — please wait for the download.")
                     : loc("Less accurate. Aloud switches to full accuracy on its own when the download finishes."))
                    .font(.footnote)
                    .foregroundStyle(basicUnavailable ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .multilineTextAlignment(.center)
            }
        }
    }

    // The one setting worth choosing before the first real dictation: how much
    // Aloud tidies what you said. It sits here, under the words the user just
    // spoke, because that's the only place the choice is concrete — and it's
    // the same card as the permission rows, so the flow gains no new shape.
    // Say it again after switching and the difference is right there.
    private var cleanUp: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 17))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(loc("Clean-up"))
                    .font(.callout.weight(.semibold))
                // Reserved space: the row can't change height as the
                // explanation changes underneath the picker.
                Text(settings.polishLevel.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Picker("", selection: $settings.polishLevel) {
                ForEach(controller.availableLevels) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        .frame(maxWidth: 380)
    }

    private var tryIt: some View {
        screen(symbol: "quote.bubble",
               title: loc("Try It"),
               message: loc("Click the box, hold %@ while you say something, then let go.", settings.hotkey.displayName)) {
            VStack(spacing: 14) {
                TextField(loc("Your words will appear here"), text: .constant(controller.lastTranscription))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                cleanUp
                if controller.usingFallback {
                    // First impressions happen on the basic engine after a
                    // skip — make clear this isn't Aloud at full strength.
                    Text(loc("You’re on basic dictation — accuracy improves on its own once setup finishes."))
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                if tryItDone {
                    Label(loc("That’s all there is to it"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                (Text(loc("Aloud lives in your menu bar — the "))
                 + Text(Image(systemName: "waveform"))
                 + Text(loc(" icon at the top of your screen.")))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if tryItDone {
                    primaryButton(loc("Continue")) { advance() }
                } else {
                    secondaryButton(loc("Skip for now")) { advance() }
                }
            }
        }
    }

    // MARK: what else Aloud does

    // A map, not a manual: six things the user would otherwise never find,
    // two words each. The ⓘ opens the same quiet popover History uses — the
    // sentence is there for whoever wants it, and costs nothing to whoever
    // doesn't. Nothing here needs doing now, so the only button is the exit.
    private struct Feature: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let tagline: String
        let detail: String
    }

    private var featureList: [Feature] {
        var items = [
            Feature(id: "handsFree", symbol: "ear",
                    title: loc("Hands-free"), tagline: loc("Talk without holding"),
                    detail: settings.handsFreeHotkey.map {
                        loc("Press %@ and Aloud keeps listening until you press Esc — good for long thoughts.", $0.displayName)
                    } ?? loc("Double-press %@ and Aloud keeps listening until you press Esc — good for long thoughts.",
                             settings.hotkey.displayName)),
            Feature(id: "vocabulary", symbol: "character.book.closed",
                    title: loc("Vocabulary"), tagline: loc("Fix words it mishears"),
                    detail: loc("Teach Aloud a name, a product, a term of art — it types your spelling from then on.")),
            Feature(id: "snippets", symbol: "text.insert",
                    title: loc("Snippets"), tagline: loc("Short phrase, long text"),
                    detail: loc("Say “my email” as the whole dictation and Aloud types the address instead.")),
            Feature(id: "appRules", symbol: "macwindow",
                    title: loc("App Rules"), tagline: loc("Match each app’s tone"),
                    detail: loc("Aloud reads the app you’re in and writes to suit it. Pin the style yourself when you’d rather decide.")),
            Feature(id: "history", symbol: "clock",
                    title: loc("History"), tagline: loc("Find anything you said"),
                    detail: loc("Every dictation is searchable, and never leaves this Mac. Copy it again, or correct it and teach Aloud the right words.")),
            Feature(id: "scratchpad", symbol: "note.text",
                    title: loc("Scratchpad"), tagline: loc("A note that floats"),
                    detail: loc("A small always-on-top window to dictate into when there’s nowhere else to put the words.")),
        ]
        if controller.commandsAvailable {
            // Only where the on-device engine exists — elsewhere the tile
            // would describe a key the user can never make work.
            items.insert(Feature(id: "commands", symbol: "wand.and.sparkles",
                                 title: loc("Voice commands"), tagline: loc("Say what to change"),
                                 detail: loc("Set a command key in Settings, then hold it and say what to do: rewrite or translate the selected text, or write something new.")),
                         at: 3)
            items.removeAll { $0.id == "scratchpad" }
        }
        return items
    }

    private var features: some View {
        // Echoes the grid below it, the way each screen's glyph names its own
        // content (waveform, lock, download arrow, speech bubble).
        screen(symbol: "square.grid.2x2",
               title: loc("What Else Aloud Does"),
               message: loc("Nothing to set up now — this is just so you know it’s there.")) {
            VStack(spacing: 14) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                    GridItem(.flexible(), spacing: 8)],
                          spacing: 8) {
                    ForEach(featureList) { feature in
                        featureTile(feature)
                    }
                }
                primaryButton(loc("Start Using Aloud")) { onFinished() }
            }
        }
    }

    private func featureTile(_ feature: Feature) -> some View {
        HStack(spacing: 8) {
            Image(systemName: feature.symbol)
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(feature.title)
                    .font(.callout.weight(.semibold))
                Text(feature.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                openFeature = openFeature == feature.id ? nil : feature.id
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(loc("What this does"))
            .popover(isPresented: Binding(get: { openFeature == feature.id },
                                          set: { if !$0, openFeature == feature.id { openFeature = nil } }),
                     arrowEdge: .bottom) {
                Text(feature.detail)
                    .font(.callout)
                    .frame(width: 260, alignment: .leading)
                    .padding(14)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    // MARK: chrome

    private func screen(symbol: String, title: String, message: String,
                        @ViewBuilder actions: () -> some View) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Color.accentColor)
                .frame(height: 52)
            VStack(spacing: 8) {
                Text(title)
                    .font(.title.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        .accessibilityElement()
        .accessibilityLabel(loc("Step %1$ld of %2$ld", step.rawValue + 1, Step.allCases.count))
    }

    // Skip steps that are already satisfied, so reopening setup (or a re-grant
    // in System Settings) never replays screens the user has completed.
    private func advance() {
        var raw = step.rawValue + 1
        while let candidate = Step(rawValue: raw), isSatisfied(candidate) { raw += 1 }
        guard let next = Step(rawValue: raw) else { return }
        if next == .tryIt { _ = controller.startListening() }
        withAnimation(.easeOut(duration: 0.22)) { step = next }
    }

    private func reclaimFocus() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.title == loc("Welcome to Aloud") }?.makeKeyAndOrderFront(nil)
    }

    // Mirror of advance(): step backwards, skipping steps that are already
    // satisfied (the poll would instantly bounce the user forward off them).
    private func retreat() {
        var raw = step.rawValue - 1
        while let candidate = Step(rawValue: raw), isSatisfied(candidate) { raw -= 1 }
        guard let prev = Step(rawValue: raw) else { return }
        withAnimation(.easeOut(duration: 0.22)) { step = prev }
    }

    private func isSatisfied(_ s: Step) -> Bool {
        switch s {
        case .access: return Permissions.allGranted
        case .voice: return controller.transcriberState == .ready
        case .welcome, .tryIt, .features: return false
        }
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
