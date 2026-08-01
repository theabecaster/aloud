import SwiftUI

// The agent-session face of the recording pill (docs/agent-voice-bridge.md
// §7.1d). Same panel, same capsule, same materials, same row — a glyph and a
// meter — because an agent session is the same event as a dictation with a
// different party on the other end, and the pill should look like it.
//
// Two things say which party that is, and neither of them is in the row:
//
//         ╭─────────────╮
//         │ fixing tests│                  ← the session, as a corner badge
//   ┌─────┴─────────────┴─────┐
//   │ (glyph)   ▁▃▅▂▃▁        │            ← phase, then voice or level
//   └─────────────────────────┘
//
// The name sits proud of the top-left corner, the way the noise badge sits on
// the top-right: a standing fact about the session, not a word in the row's
// sentence. The colour is the accent below.
//
// The words are not here. What was said, and what is about to be sent, live in
// the chat panel that opens above the pill (AgentChatPanel.swift) — a rolling
// two-line tail inside the capsule could show that something had been heard but
// never what was going to be sent, which is the only question a person actually
// has while an agent is holding their microphone.

extension Color {
    /// The agent accent: a soft sea-green. It has to answer one question at a
    /// glance — *is this me or is this an agent?* — so it may not be any colour
    /// the pill already uses for something the user did (red dictation, orange
    /// hands-free, purple command) nor Aloud's own blue, which already means
    /// "the app is doing something to your audio".
    ///
    /// It is deliberately desaturated and slightly green of teal. The first cut
    /// used `Color.teal`, which at capsule-fill strength read as *blue* next to
    /// Aloud's own — the pill looked like a loud version of the app's colour
    /// rather than a different one. Muted, it stays legible at the edge of
    /// vision without shouting, which matters for a pill that can be up for a
    /// whole conversation.
    static let agent = Color(red: 0.24, green: 0.72, blue: 0.63)

    /// The same hue lifted for dark backgrounds — glyphs and bar meters, where
    /// the muted fill above goes muddy against the pill's own material.
    static let agentBright = Color(red: 0.33, green: 0.84, blue: 0.73)
}

// What the harness is doing, as far as the bridge can actually know it
// (§7.1d "Open:"): a request is waiting on the user, the mic is open, Aloud is
// speaking for the agent, or the exchange is over. Nothing here is inferred
// from silence — the controller sets it from the bridge's own transitions.
enum AgentIndicatorPhase: Equatable {
    case pending    // an agent asked; the user has not answered
    case listening  // the mic is open and the words go to the agent
    case speaking   // the agent is talking through the speakers
    case done       // the exchange finished

    // One glyph per phase, in a slot that never moves.
    var symbol: String {
        switch self {
        // The system's own "a permission decision is being asked of you" mark.
        case .pending:   return "hand.raised.fill"
        // The same mic the dictation pill uses — an open microphone looks the
        // same whoever opened it; the colour is what says who.
        case .listening: return "mic.fill"
        case .speaking:  return "speaker.wave.2.fill"
        case .done:      return "checkmark.circle.fill"
        }
    }

    var help: String {
        switch self {
        case .pending:   return loc("Waiting for your answer")
        case .listening: return loc("Listening — this goes to the agent")
        case .speaking:  return loc("The agent is speaking")
        case .done:      return loc("Done")
        }
    }
}

struct AgentIndicatorContent: View {
    @ObservedObject var model: IndicatorModel
    // The slot on screen, which lags `slotKind` only when the new state is a
    // wait (see `spinnerGrace`), and the counter that lets a state arriving
    // inside that grace cancel the spinner that was queued behind it.
    @State private var shownKind: SlotKind = .empty
    @State private var graceGeneration = 0

    // The dictation pill's meter, to the point: same size, same slot. The voice
    // wave takes it too, so Aloud talking and Aloud listening occupy exactly the
    // same space and the pill never resizes between them.
    static let meterWidth: CGFloat = 90
    static let meterHeight: CGFloat = 18

    var body: some View {
        HStack(spacing: 10) {
            phaseGlyph
            voiceSlot
            if model.consent != nil {
                consentControls
            }
        }
        // Every change of what the pill is doing is a change of one slot, and
        // they all move on the same spring: the glyph replaces itself, the slot
        // crossfades and rescales, the controls fade. Nothing in the row is
        // allowed to appear or vanish on a frame boundary.
        .animation(.spring(duration: 0.28), value: model.consent)
        .animation(.spring(duration: 0.28), value: model.agentPhase)
        .animation(.spring(duration: 0.28), value: shownKind)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(loc("Agent Speak"))
    }

    // MARK: pieces

    // What the pill is doing, in the slot the meter would otherwise fill: the
    // helix while Aloud is talking, the level once the mic is live, the question
    // while a decision is pending.
    //
    // Nothing is held open when there is nothing to put in it. A finished turn
    // used to keep the meter's 90 points anyway and drew a checkmark beside a
    // gap the width of the pill, which read as something failing to load.
    // What the slot is showing, as one value — so a change from any of these to
    // any other is a single animated swap rather than four independent
    // appearances racing each other.
    private enum SlotKind: Equatable {
        case voice, preparing, meter, settling, question, empty

        // Whether this state fills the meter's slot. The spinners and the
        // finished pill size to their contents instead.
        var holdsFullWidth: Bool {
            switch self {
            case .voice, .meter, .question: return true
            case .preparing, .settling, .empty: return false
            }
        }
    }

    private var slotKind: SlotKind {
        if isSpeaking { return model.voiceIsPlaying ? .voice : .preparing }
        if micIsOpen { return .meter }
        if model.chatIsSettling { return .settling }
        if model.consent != nil { return .question }
        // Accepted, and whatever comes next — the agent speaking, or the
        // microphone opening — has not arrived yet. Left empty, this was the
        // ugliest moment in the whole flow: the buttons left, the question left,
        // the pill collapsed to a lone glyph and then sprang open again a beat
        // later for the wave. The spinner holds the slot through the handover so
        // the pill changes once, not three times.
        if model.agentPhase == .listening { return .preparing }
        return .empty
    }

    // What the slot is actually showing. It follows `slotKind` immediately in
    // every direction but one: a wait only earns a spinner if it lasts. With a
    // warm engine the gap between accepting and hearing the voice is a couple
    // of hundred milliseconds, and a spinner shown across it is a flash and two
    // resizes — the pill stuttering rather than working. Optimism first: hold
    // the state we were in, and admit to waiting only if the wait is real.
    private static let spinnerGrace = Duration.milliseconds(380)

    private var voiceSlot: some View {
        slotContent
            .id(shownKind)
            // The old slot shrinks away and the new one grows in its place,
            // both centred: the pill's width travels between the two sizes
            // instead of jumping.
            .transition(.scale(scale: 0.7).combined(with: .opacity))
            // The meter, the wave and the question all hold one width, so the
            // capsule doesn't resize as they swap. The waiting states are not in
            // that club: a spinner in a 90-point slot is a small thing pinned to
            // the left of a pill's worth of empty space. It gets the width it
            // needs, and the capsule grows into the wave when the wave arrives.
            .frame(minWidth: shownKind.holdsFullWidth ? Self.meterWidth : 0, alignment: .leading)
            .onAppear { shownKind = slotKind }
            .onChange(of: slotKind) { _, new in
                graceGeneration += 1
                let generation = graceGeneration
                guard new == .preparing || new == .settling else {
                    return withAnimation(.spring(duration: 0.28)) { shownKind = new }
                }
                Task { @MainActor in
                    try? await Task.sleep(for: Self.spinnerGrace)
                    guard generation == graceGeneration else { return }
                    withAnimation(.spring(duration: 0.28)) { shownKind = new }
                }
            }
    }

    @ViewBuilder
    private var slotContent: some View {
        switch shownKind {
        // Only once sound is actually coming out. The enhanced voice
        // synthesizes first, which can take a second or two, and a helix drawn
        // through that silence is a picture of speech that has not started.
        case .voice:
            voice
        case .meter:
            meter
        // Waiting on us: the voice being prepared, the handover after an accept,
        // or the words being settled at the end of a turn. All three are the
        // same thing to the user — the pill is working — so all three look the
        // same.
        case .preparing, .settling:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 20, height: Self.meterHeight)
        case .empty:
            EmptyView()
        case .question:
            // The badge above already says who is asking, so the row only has
            // to say what is being asked. "Open the mic?" is the whole of it:
            // the decision is about the microphone, and it is a question, which
            // the two buttons beside it then answer.
            Text(loc("Open the mic?"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        // Nothing at all once the turn is sent. The pill collapses around the
        // checkmark — see `agentIsDone` in the pill's padding — because the
        // ending should feel like the thing closing, not like a pill that has
        // run out of things to say. A word beside the tick ("Sent") said the
        // same thing more slowly and left the pill at full width while it did.
    }

    // The phase, as one glyph in one place. Each symbol crossfades and scales
    // into the next rather than being swapped by SF Symbols' own replace
    // transition: that effect was fighting the size change on the finished
    // state and the variable-colour animation on the speaking one, and the
    // result read as a flicker between two icons instead of one becoming the
    // other.
    private var phaseGlyph: some View {
        ZStack {
            Image(systemName: model.agentPhase.symbol)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color.agentBright)
                .symbolEffect(.variableColor.iterative, isActive: model.agentPhase == .speaking)
                .id(model.agentPhase.symbol)
                .transition(.scale(scale: 0.55).combined(with: .opacity))
        }
        // One slot, one size, whichever glyph is in it.
        .frame(width: 18, height: 18)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.agentPhase)
        .help(model.agentPhase.help)
    }

    // Consent mode 2 lives here rather than on a surface of its own: the pill
    // that is about to listen is the thing being agreed to. Filled circles in
    // the noise badge's idiom, so they read as pressable on a translucent
    // capsule; accept carries the agent accent, decline stays neutral — a red
    // "no" would shout louder than the question does.
    private var consentControls: some View {
        HStack(spacing: 8) {
            Button { model.onDeclineConsent?() } label: {
                consentGlyph("xmark", filled: false)
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .help(loc("Decline — or press Esc"))
            .accessibilityLabel(loc("Decline — or press Esc"))
            Button { model.onAcceptConsent?() } label: {
                consentGlyph("checkmark", filled: true)
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .help(loc("Accept — or press the Aloud hotkey"))
            .accessibilityLabel(loc("Accept — or press the Aloud hotkey"))
        }
        // The two buttons shrink toward the slot they were attached to, so an
        // answered question closes inward rather than leaving a hole the pill
        // then has to collapse.
        .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
    }

    private var meter: some View {
        SpectrumMeter(bands: model.bands, tint: .agentBright)
            .frame(width: Self.meterWidth, height: Self.meterHeight)
    }

    private var voice: some View {
        VoiceWave(level: model.level, tint: .agentBright)
            .frame(width: Self.meterWidth, height: Self.meterHeight)
    }

    private func consentGlyph(_ symbol: String, filled: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: 22, height: 22)
            .background {
                Circle().fill(filled ? AnyShapeStyle(Color.agent) : AnyShapeStyle(.regularMaterial))
            }
            .overlay(Circle().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }

    // MARK: state

    private var isSpeaking: Bool { model.agentPhase == .speaking }

    // Whether the microphone is actually capturing, asked of the controller
    // rather than inferred from the consent mode. Confirm-by-voice does open
    // the mic before consent exists, but not until the spoken question has
    // finished playing — inferring it from the mode drew a meter over a closed
    // microphone for those several seconds.
    //
    // ...and never once the turn is over, whatever the capture side has got
    // round to: a finished exchange under a moving meter says the microphone is
    // still open, which is the one thing this pill may never get wrong.
    private var micIsOpen: Bool { model.micIsLive && model.agentPhase != .done }
}
