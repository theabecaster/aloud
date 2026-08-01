import SwiftUI

// What an agent session actually looks like, as opposed to what it is doing.
//
// The pill says an agent has the microphone and whether it is listening or
// talking. It cannot say *what was said*, and while an agent holds the mic that
// is the only question a person has: what did it ask, and what is about to be
// sent back in my name. This is that surface — a thread, one per lease, opening
// upward out of the pill:
//
//   ┌───────────────────────────────┐
//   │ ┌───────────────────────┐     │   ← the agent, on the left
//   │ │ Rename the migration? │     │
//   │ └───────────────────────┘     │
//   │      ┌──────────────────────┐ │   ← what was sent, on the right
//   │      │ yes, go ahead        │ │
//   │      └──────────────────────┘ │
//   │ ┌───────────────────────────┐ │   ← the live draft, being composed
//   │ │ but keep the old column…▎ │ │
//   │ └───────────────────────────┘ │
//   └───────────────────────────────┘
//              ▲ opens out of the pill
//
// The composing row is the point of the whole thing. An agent session sends one
// batch of text at the end of a turn, and until it goes the user has no way to
// see what they are about to say — so the words gather in a draft field exactly
// like a message being typed, and when the turn ends the draft is *sent*: it
// flies up into the thread as the message the agent received. What the agent
// hears and what the user saw leave are then the same object.
//
// Agent bubbles carry only the final, concise thing the agent chose to say.
// That is a token-cost decision as much as a design one: the panel is a mirror
// of the bridge traffic, so keeping it short keeps the traffic short.

// Applies the shared identity only to the one bubble that just came out of the
// composer. Two live views may never claim the same geometry id, so this has to
// be conditional, and a conditional modifier is the only way to say that
// without changing the view's own type on every message.
private struct SendGeometry: ViewModifier {
    let active: Bool
    let id: String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if active {
            content.matchedGeometryEffect(id: id, in: namespace)
        } else {
            content
        }
    }
}

struct AgentChatMessage: Identifiable, Equatable {
    enum Author: Equatable { case agent, user }
    let id: Int
    let author: Author
    var text: String
}

struct AgentChatPanel: View {
    @ObservedObject var model: IndicatorModel
    // Which edge the pill is on. The reveal has to open out of the pill, so on
    // a pill dragged to the top of the screen — where the panel hangs below it
    // instead — the circle starts at the top edge rather than the bottom.
    var opensDownward = false
    // The draft field and the bubble it becomes are the same object as far as
    // the eye is concerned, so they are the same object as far as the layout is
    // concerned too: the send is one view travelling from the composer up into
    // the thread, not one view leaving and another arriving.
    @Namespace private var sendNamespace
    private static let sendID = "agent-chat-send"

    // Wider than the pill — it holds sentences, not a meter — and capped in
    // height at roughly a third of a laptop screen, after which the thread
    // scrolls with the newest message pinned. A panel that grew with the
    // conversation would end up covering the window the user is working in,
    // which is the thing this feature exists to keep them out of.
    static let width: CGFloat = 320
    static let maxThreadHeight: CGFloat = 240
    // How far the draft may grow before it starts scrolling instead. Roughly
    // eight lines — long enough for the answers people actually give out loud.
    static let maxDraftHeight: CGFloat = 130
    // The gap between the panel and the pill it opens out of.
    static let gap: CGFloat = 10

    // The reveal, in the noise badge's idiom (RecordingIndicatorPanel): the
    // outline arrives first and the contents fill in behind it, both wiped in by
    // a circle opening out from the pill below. Two values rather than one so
    // the line is drawn before the wash, and both reverse for free on the way
    // out.
    @State private var borderReveal: CGFloat = 0
    @State private var bodyReveal: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thread
            if model.chatDraftIsVisible {
                composer
            }
        }
        .padding(10)
        .frame(width: Self.width)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 18).fill(Color.agent.opacity(0.07))
                    .mask { revealMask(bodyReveal) }
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.agent.opacity(0.45), lineWidth: 1)
                    .mask { revealMask(borderReveal) }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 18)
            .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
        // The whole panel is wiped in by the same circle, so it appears to be
        // pulled up out of the pill rather than dropped on top of it.
        .mask { revealMask(bodyReveal) }
        .onAppear {
            withAnimation(.easeOut(duration: 0.28)) { borderReveal = 1 }
            withAnimation(.easeOut(duration: 0.5)) { bodyReveal = 1 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(loc("Agent conversation"))
    }

    // MARK: thread

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.chatMessages) { message in
                        bubble(message)
                            .id(message.id)
                            // A sent message arrives from the draft field
                            // below, which is where the user just watched it
                            // being written.
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity))
                    }
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Self.maxThreadHeight)
            // Newest pinned: the thread is read from the bottom, like every
            // other conversation on this machine.
            .onChange(of: model.chatMessages.count) { _, _ in
                guard let last = model.chatMessages.last else { return }
                withAnimation(.spring(duration: 0.35)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onAppear {
                guard let last = model.chatMessages.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
        // Collapses to nothing before the first message rather than reserving
        // an empty box above the draft.
        .frame(height: model.chatMessages.isEmpty ? 0 : nil)
        .opacity(model.chatMessages.isEmpty ? 0 : 1)
    }

    private func bubble(_ message: AgentChatMessage) -> some View {
        let isUser = message.author == .user
        return HStack(spacing: 0) {
            if isUser { Spacer(minLength: 32) }
            Text(message.text)
                .font(.system(size: 12))
                .foregroundStyle(isUser ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isUser ? AnyShapeStyle(Color.agent) : AnyShapeStyle(.regularMaterial))
                }
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.separator.opacity(isUser ? 0 : 0.5), lineWidth: 0.5))
                // The message that just left the composer carries the composer's
                // identity, so it flies up from the field instead of appearing
                // above it.
                .modifier(SendGeometry(active: message.id == model.lastSentMessageID,
                                       id: Self.sendID,
                                       namespace: sendNamespace))
            if !isUser { Spacer(minLength: 32) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    // MARK: composer

    // The turn being written. Deliberately shaped like a message field with a
    // send button: it is the one thing on screen that says the words are not
    // gone yet — and, once the turn ends, that they have.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            draftText
            sendGlyph
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
        }
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color.agent.opacity(model.chatDraft.isEmpty ? 0.2 : 0.45), lineWidth: 1))
        .matchedGeometryEffect(id: Self.sendID, in: sendNamespace)
        // It rises into place under the conversation when the microphone opens,
        // and leaves upward at the moment of the send, into the space the new
        // bubble is arriving in. Both directions travel the same axis, so the
        // panel reads as one surface changing rather than two views swapping.
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)))
    }

    // The words as they arrive. It grows with them rather than holding a
    // fixed two or three lines: a capped field truncated the head, so a long
    // answer scrolled its own beginning away and the user watched the sentence
    // they were still speaking eat the one they had just finished. It grows to
    // a ceiling of its own and only then scrolls, newest line in view.
    private var draftText: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                Group {
                    if model.chatDraft.isEmpty {
                        Text(model.chatDraftPlaceholder)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(model.chatDraft)
                            .foregroundStyle(.primary)
                    }
                }
                .font(.system(size: 12))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(Self.draftAnchor)
            }
            .frame(maxHeight: Self.maxDraftHeight)
            .scrollDisabled(false)
            .onChange(of: model.chatDraft) { _, _ in
                proxy.scrollTo(Self.draftAnchor, anchor: .bottom)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private static let draftAnchor = "draft"

    @ViewBuilder
    private var sendGlyph: some View {
        if model.chatIsSettling {
            // Between the last word and the send: the draft is closed, and this
            // is what says the message is on its way rather than stalled.
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
                .transition(.opacity)
        } else {
            paperPlane
        }
    }

    private var paperPlane: some View {
        Image(systemName: "paperplane.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(model.chatDraft.isEmpty ? AnyShapeStyle(.tertiary)
                                                     : AnyShapeStyle(Color.agentBright))
            .rotationEffect(.degrees(model.chatIsSending ? -25 : 0))
            .offset(x: model.chatIsSending ? 10 : 0, y: model.chatIsSending ? -10 : 0)
            .opacity(model.chatIsSending ? 0 : 1)
            .animation(.easeIn(duration: 0.22), value: model.chatIsSending)
            .accessibilityHidden(true)
    }

    // A circle centred on the pill below and opening out until it covers the
    // panel — the same figure the noise badge uses, anchored at the other end.
    private func revealMask(_ progress: CGFloat) -> some View {
        GeometryReader { geo in
            let reach = 2 * sqrt(geo.size.width * geo.size.width
                                 + geo.size.height * geo.size.height)
            Circle()
                .frame(width: reach * progress, height: reach * progress)
                .position(x: geo.size.width / 2,
                          y: opensDownward ? -Self.gap : geo.size.height + Self.gap)
        }
    }
}
