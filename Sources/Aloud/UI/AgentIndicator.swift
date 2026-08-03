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
    case waiting    // the question was asked out loud; the mic is open and the room is empty
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
        //
        // Waiting shares it, deliberately. The microphone genuinely *is* open
        // through a hold — that is the whole point, so the user can walk back
        // in and simply talk — and a quieter glyph would be the pill
        // understating what it is doing. What changes is the slot beside it,
        // which says "waiting" instead of drawing a meter of an empty room.
        case .waiting, .listening: return "mic.fill"
        case .speaking:  return "speaker.wave.2.fill"
        case .done:      return "checkmark.circle.fill"
        }
    }

    var help: String {
        switch self {
        case .pending:   return loc("Waiting for your answer")
        case .waiting:   return loc("Listening whenever you’re ready — just start talking")
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
        case voice, preparing, meter, waiting, settling, question, empty

        // Whether this state fills the meter's slot. The spinners and the
        // finished pill size to their contents instead.
        var holdsFullWidth: Bool {
            switch self {
            case .voice, .meter, .question: return true
            // Sized to its own two words instead. Holding the meter's 90 points
            // put "Waiting" at the left of a pill's worth of nothing, and this
            // is the state the pill sits in longest — up to ten minutes, on
            // screen, mostly being seen out of the corner of an eye. It should
            // take the room it needs and no more. The pill grows back into the
            // meter when somebody speaks, which is a transition worth seeing.
            case .waiting, .preparing, .settling, .empty: return false
            }
        }
    }

    private var slotKind: SlotKind {
        if isSpeaking { return model.voiceIsPlaying ? .voice : .preparing }
        // Before the meter, and while the mic is genuinely open: a hold can run
        // for ten minutes, and a spectrum of an empty room is a flat line that
        // reads as broken. Same width, so the pill does not resize when
        // somebody finally speaks and the meter takes the slot back.
        if model.agentPhase == .waiting { return .waiting }
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
                // Assigned plainly: the row already declares
                // `.animation(_, value: shownKind)`, and wrapping the same
                // change in `withAnimation` ran it twice — two springs on one
                // swap, which is what made the end of a turn look stuttery
                // rather than fast.
                guard new == .preparing || new == .settling else {
                    shownKind = new
                    return
                }
                Task { @MainActor in
                    try? await Task.sleep(for: Self.spinnerGrace)
                    guard generation == graceGeneration else { return }
                    shownKind = new
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
        case .waiting:
            waiting
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
                // Deliberately the whole `.speaking` phase, synthesis included,
                // rather than only while samples are leaving the speakers.
                // Gating it on `voiceIsPlaying` was tried — it is more literal,
                // since synthesis can run 2.2s before any audio — and it made
                // the talking animation itself unreliable, which is a far worse
                // trade than a glyph that starts pulsing slightly early.
                .symbolEffect(.variableColor.iterative, isActive: model.agentPhase == .speaking)
                .id(model.agentPhase.symbol)
                .transition(.scale(scale: 0.55).combined(with: .opacity))
        }
        // One slot, one size, whichever glyph is in it.
        .frame(width: 18, height: 18)
        // No spring of its own. The row already animates on `agentPhase`, and a
        // second curve on the same trigger meant the glyph and the slot beside
        // it were moving to different timings — most visible at the end of a
        // turn, where the spinner leaving and the tick arriving are one event
        // and read as two.
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

    // The held session, in the meter's slot.
    //
    // The pill may sit like this for ten minutes while somebody is in another
    // room, so it has to be legible from across that room and still be
    // something you would not mind having on screen. One word and three dots
    // that breathe: alive enough that it is plainly not a frozen pill, quiet
    // enough that it is not asking for attention it does not need.
    //
    // Deliberately not a spinner. A spinner means Aloud is working on
    // something; nothing is happening here except a room being listened to.
    private var waiting: some View {
        HStack(spacing: 6) {
            Text(loc("Waiting"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            BreathingDots(tint: .agentBright)
        }
        .frame(height: Self.meterHeight)
        .fixedSize()
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

// Three dots that rise and fade in turn, for a pill that may be waiting for a
// long time.
//
// Written by hand rather than reached for from the system: `ProgressView` says
// Aloud is busy, and `symbolEffect(.pulse)` on an ellipsis moves all three
// together, which reads as a warning rather than as patience. The offset phase
// is the whole effect — it is what makes it look like waiting instead of
// blinking.
//
// One animation, started on appear and never restarted, so a pill up for ten
// minutes is not scheduling anything per frame beyond the implicit interpolation.
private struct BreathingDots: View {
    let tint: Color
    @State private var breathing = false

    private static let period: TimeInterval = 1.4
    private static let dots = 3

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<Self.dots, id: \.self) { index in
                Circle()
                    .fill(tint)
                    .frame(width: 4, height: 4)
                    .opacity(breathing ? 1 : 0.25)
                    .animation(
                        .easeInOut(duration: Self.period)
                            .repeatForever(autoreverses: true)
                            // Each dot a third of a cycle behind the last, so
                            // the brightness travels along the row.
                            .delay(Double(index) * Self.period / Double(Self.dots)),
                        value: breathing)
            }
        }
        .onAppear { breathing = true }
        .accessibilityHidden(true)
    }
}
