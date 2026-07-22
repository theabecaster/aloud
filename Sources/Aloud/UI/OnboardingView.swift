import SwiftUI

// First-run flow, Setup Assistant style: one instruction per screen, a single
// primary button, progress dots. Screens for permissions poll live status and
// auto-advance the moment the user grants access in System Settings.
struct OnboardingView: View {
    @ObservedObject var controller: DictationController
    let onFinished: () -> Void

    enum Step: Int, CaseIterable {
        case welcome, microphone, accessibility, model, tryIt
    }

    @State private var step: Step = .welcome
    @State private var micStatus = Permissions.microphone
    @State private var axStatus = Permissions.accessibility
    @State private var micDeniedOnce = false
    @State private var tryItDone = false

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
        .onReceive(poll) { _ in
            micStatus = Permissions.microphone
            axStatus = Permissions.accessibility
            // Auto-advance when a permission screen's requirement is met.
            if step == .microphone, micStatus == .granted { advance() }
            if step == .accessibility, axStatus == .granted {
                _ = controller.startListening()
                advance()
            }
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
        case .tryIt: tryIt
        }
    }

    // MARK: screens

    private var welcome: some View {
        screen(symbol: "waveform",
               title: "Welcome to Aloud",
               message: "Hold a key, speak, and your words appear wherever you’re typing. Everything happens on your Mac — nothing you say ever leaves it.") {
            primaryButton("Continue") { advance() }
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
               title: "Allow Accessibility",
               message: "This lets your dictation key work in every app, and lets Aloud type the words for you. macOS calls this “Accessibility” access.") {
            VStack(spacing: 12) {
                if axStatus == .denied {
                    Text("In System Settings, turn on Aloud under Privacy & Security → Accessibility. This screen will move on automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                primaryButton(axStatus == .denied ? "Open System Settings" : "Allow Accessibility") {
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            }
        }
    }

    private var model: some View {
        screen(symbol: "arrow.down.circle",
               title: "Set Up Your Voice",
               message: "Aloud downloads its voice recognition once (about 500 MB). After this, dictation works completely offline — forever.") {
            VStack(spacing: 14) {
                switch controller.transcriberState {
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
        .onAppear {
            if controller.transcriber.modelIsDownloaded {
                Task { await controller.prepareModel() }
            }
        }
    }

    private var tryIt: some View {
        screen(symbol: "quote.bubble",
               title: "Try It",
               message: "Click into the field below, hold \(controller.settings.hotkey.displayName), say something, and let go.") {
            VStack(spacing: 16) {
                TextField("Your words will appear here", text: .constant(controller.lastTranscription))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                if tryItDone {
                    Label("That’s it — you’re set", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    primaryButton("Done") { onFinished() }
                } else {
                    Button("Skip for now") { onFinished() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
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
        Button(action: action) {
            Text(label)
                .frame(minWidth: 160)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
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

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        withAnimation(.spring(duration: 0.3)) { step = next }
    }
}
