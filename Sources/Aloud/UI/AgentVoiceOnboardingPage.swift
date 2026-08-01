import SwiftUI

// The onboarding screen where agent voice is opted into — and the only place a
// new user meets the feature at all.
//
// It is a consent screen before it is a feature pitch: turning it on hands
// local processes the microphone and the speakers, so the screen says that in
// plain sentences and gives the two answers equal weight. Skipping is a real
// answer, not a detour: it writes the decision (off) exactly as the enabling
// path writes its own, so the setting is always something the user chose rather
// than something inferred from a screen they clicked past.
//
// Scope is deliberately small: the decision and the explanation. Which agents
// get wired up, and how each listen is approved, belong to Settings → Agent Speak —
// this page just hands control back through `onEnable` / `onSkip`.
//
// New strings here still need entries in Sources/Aloud/Resources/*.lproj
// (en, es, de, fr, pt-BR) — they are shared files, added separately.
struct AgentVoiceOnboardingPage: View {
    @ObservedObject var settings: SettingsStore
    /// The feature is on — carry on to whatever comes next (setup, or the rest
    /// of the flow). Called after the gate has been flipped on.
    let onEnable: () -> Void
    /// The user declined. The gate has been written off; move on as if the
    /// screen had never appeared.
    let onSkip: () -> Void

    private var isOn: Bool { settings.experimentalAgentVoice }

    var body: some View {
        screen(symbol: "bubble.left.and.bubble.right",
               title: loc("Let Agents Ask You Out Loud"),
               message: loc("A coding agent can ask you a question out loud and hear your answer, so you can keep working instead of switching to its window.")) {
            VStack(spacing: 14) {
                grants
                Text(loc("This is experimental. You can turn it on or off any time in Settings."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                choice
            }
        }
    }

    // What is actually being granted, said once and without hedging: two
    // capabilities, then the two things that keep them honest.
    private var grants: some View {
        VStack(spacing: 0) {
            grantRow(symbol: "mic",
                     title: loc("Agents can turn on the microphone"),
                     detail: loc("To hear your answer to a question they asked."))
            Divider().padding(.leading, 46)
            grantRow(symbol: "speaker.wave.2",
                     title: loc("Agents can speak through your speakers"),
                     detail: loc("That is how the question reaches you."))
            Divider().padding(.leading, 46)
            grantRow(symbol: "eye",
                     title: loc("You always see it happening"),
                     detail: loc("The recording indicator appears every time, and names the agent."))
            Divider().padding(.leading, 46)
            grantRow(symbol: "lock",
                     title: loc("Nothing leaves this Mac"),
                     detail: loc("Questions and answers stay on this Mac, like the rest of Aloud."))
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    private func grantRow(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    // Two buttons, same size and shape, side by side: the accent fill marks
    // which one continues the flow, not which one is allowed to be clicked.
    // Both write the decision — neither leaves the setting to inference — and
    // both labels state their effect when the gate is already on, so coming
    // back to this screen never hides what the buttons will do.
    private var choice: some View {
        HStack(spacing: 12) {
            Button(isOn ? loc("Turn Off") : loc("Not Now")) {
                settings.experimentalAgentVoice = false
                onSkip()
            }
            .buttonStyle(AgentVoiceOnboardingButtonStyle())

            Button(isOn ? loc("Continue") : loc("Turn On")) {
                settings.experimentalAgentVoice = true
                onEnable()
            }
            .buttonStyle(AgentVoiceOnboardingButtonStyle(prominent: true))
            .keyboardShortcut(.defaultAction)
        }
    }

    // Same chrome as every other onboarding screen: one glyph naming the
    // screen, a title, a secondary line, then whatever the screen asks for.
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
}

// Mirrors the onboarding flow's button style, which is file-private to
// OnboardingView. Kept identical on purpose — flat fills that read correctly in
// both appearances, accent for the one action that continues the flow. Fold the
// two together if the style ever moves somewhere shared.
private struct AgentVoiceOnboardingButtonStyle: ButtonStyle {
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
