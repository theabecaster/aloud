import SwiftUI

// The agent-session face of the recording pill (docs/agent-voice-bridge.md
// §7.1d). Same panel, same capsule, same materials — one new accent colour and
// two jobs the dictation pill never had to do:
//
//   1. Show what was heard. A dictation types into the focused app, so its pill
//      only needs a meter; an agent session injects nothing, so this is the only
//      place the words appear at all. A rolling tail, not a scrollback: a line
//      or two, fading out at the top edge. It says "it heard me", it is not a
//      document.
//   2. Show what the harness is doing, as one glyph in a fixed slot, so the eye
//      learns one place to look.
//
// Layout is three fixed slots and one changing row, in that order:
//
//   ┌──────────────────────────────────────────┐
//   │ (glyph)  caller / question        ▁▃▅▂   │   ← fixed: phase, name, meter
//   │ what you just said, rolling …            │   ← transcript, or accept/deny
//   └──────────────────────────────────────────┘
//
// The width is fixed and only the second row grows, because words arrive a few
// at a time: a pill that re-measured itself per word would twitch continuously
// while someone is mid-sentence, which is the opposite of a confidence signal.

extension Color {
    /// The agent accent: teal. It has to answer one question at a glance —
    /// *is this me or is this an agent?* — so it may not be any colour the pill
    /// already uses for something the user did (red dictation, orange
    /// hands-free, purple command) nor Aloud's own blue, which already means
    /// "the app is doing something to your audio". Teal is the remaining cool
    /// hue in the system palette: unmistakably not-red at the edge of vision,
    /// calm rather than alarming, and it still sits in the same family as the
    /// blue so the pill reads as the same app.
    static let agent = Color.teal
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

    // Fixed so streaming words can't jitter the pill's width. Wide enough for
    // roughly two short lines of transcript at 12 pt, narrow enough that the
    // thing is still a pill.
    private static let width: CGFloat = 296
    private static let transcriptFont: CGFloat = 12
    // Two lines' worth. Held even for a one-line tail, so the pill grows once
    // when the first words land and then holds still for the rest of the turn.
    private static let transcriptHeight: CGFloat = 32
    // Longest tail we keep. Past this the head is dropped rather than the
    // fade being asked to hide four lines of text.
    private static let tailLimit = 96

    var body: some View {
        Group {
            if model.consent != nil { asking } else { session }
        }
        .animation(.spring(duration: 0.28), value: model.consent)
        .animation(.spring(duration: 0.28), value: tail.isEmpty)
        .animation(.spring(duration: 0.28), value: model.agentPhase)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(loc("Agent Speak"))
    }

    // A question and two buttons. One row, sized to its content — the session
    // layout below is built around a transcript that this state never has, and
    // wearing it made a yes/no question the largest thing on the screen.
    //
    // Everything in the row moves at the swap, because one changing thing was
    // easy to miss: the glyph turns from a raised hand into a microphone at the
    // same moment the voice becomes a meter, alongside the start cue. Aloud
    // asking and Aloud listening should not look alike.
    private var asking: some View {
        HStack(spacing: 8) {
            phaseGlyph
            Text(headline)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if isSpeaking {
                voice
            } else if micIsOpen {
                meter
            }
            consentControls
        }
        .fixedSize()
    }

    private var session: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                phaseGlyph
                Text(headline)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 6)
                // The trailing slot answers "what does this want from me": the
                // voice while Aloud is talking, the level once the mic is live.
                // The meter appears only while the microphone is genuinely
                // open — a resting meter would say it was on before it is.
                if isSpeaking {
                    voice
                } else if micIsOpen {
                    meter
                }
            }
            // A capsule curves away from its corners: at the height of the top
            // row the right-hand edge has crept several points inwards, and
            // without this the meter's last bars sit on the border.
            .padding(.trailing, 6)
            if !tail.isEmpty {
                transcript
            }
        }
        .frame(width: Self.width, alignment: .leading)
    }

    // MARK: pieces

    private var phaseGlyph: some View {
        Image(systemName: model.agentPhase.symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.agent)
            // One slot, one size, whichever glyph is in it.
            .frame(width: 18, height: 18)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.variableColor.iterative, isActive: model.agentPhase == .speaking)
            .help(model.agentPhase.help)
    }

    // The rolling tail. Bottom-aligned in a two-line box and masked so the top
    // edge dissolves: what was said a moment ago is on its way out rather than
    // cut off, and the newest words are the solid ones.
    private var transcript: some View {
        Text(tail)
            .font(.system(size: Self.transcriptFont))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: Self.transcriptHeight, alignment: .bottomLeading)
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black, location: 0.5)],
                               startPoint: .top, endPoint: .bottom)
            )
            .transition(.opacity)
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
            Button { model.onAcceptConsent?() } label: {
                consentGlyph("checkmark", filled: true)
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .help(loc("Accept — or press the Aloud hotkey"))
        }
        .transition(.opacity)
    }

    private var meter: some View {
        SpectrumMeter(bands: model.bands, tint: .agent)
            .frame(width: 58, height: 16)
    }

    private var voice: some View {
        VoiceWave(level: model.level, tint: .agent)
            .frame(width: 44, height: 16)
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

    // MARK: wording

    // Who is asking, or who is listening. The name appears only where there is
    // real ambiguity to resolve — with one harness installed "an agent" is the
    // clearer thing to say (§7.1c), the same rule ConsentPrompt.text follows.
    private var caller: String { model.agentCaller ?? loc("An agent") }

    private var headline: String {
        guard model.consent != nil else { return caller }
        return model.agentCaller.map { loc("%@ wants to listen", $0) }
            ?? loc("An agent wants to listen")
    }

    private var isSpeaking: Bool { model.agentPhase == .speaking }

    // Whether the microphone is actually capturing, asked of the controller
    // rather than inferred from the consent mode. Confirm-by-voice does open
    // the mic before consent exists, but not until the spoken question has
    // finished playing — inferring it from the mode drew a meter over a closed
    // microphone for those several seconds.
    private var micIsOpen: Bool { model.micIsLive }

    private var tail: String { Self.tail(model.agentTranscript, limit: Self.tailLimit) }

    // The last few words, starting on a word boundary so the tail never opens
    // mid-word. Line breaks collapse: this is one running utterance, not text
    // with a shape.
    static func tail(_ text: String, limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        let cut = flat.suffix(limit)
        guard let space = cut.firstIndex(of: " ") else { return String(cut) }
        return String(cut[cut.index(after: space)...])
    }
}
