import AppKit
import SwiftUI

/// A data-rich status item popover. A regular NSMenu is right for commands,
/// but recent dictations are content: they need readable text, scrolling, and
/// contextual actions without turning every transcript into a submenu.
struct StatusMenuView: View {
    struct AttentionAction: Identifiable {
        // Most of these are invitations — an update to take, a model to
        // download. A warning is different in kind: Aloud is broken until it's
        // dealt with, and it has to read that way rather than as one more
        // optional errand in the same blue.
        enum Tone { case invitation, warning }

        let id: String
        let title: String
        let symbol: String
        var detail: String? = nil
        var tone: Tone = .invitation
        let action: () -> Void
    }

    /// A one-tap action on the dictation that just happened. These used to
    /// live behind an ellipsis menu; they're only useful for a few seconds
    /// after a dictation, which is exactly when a hidden menu is the wrong
    /// place for them.
    private struct QuickAction: Identifiable {
        let id: String
        /// Short enough that three of them fit the popover's width; the
        /// unabbreviated wording stays in the tooltip.
        let title: String
        let help: String
        let symbol: String
        let action: () -> Void
    }

    @ObservedObject var controller: DictationController
    @ObservedObject private var history: HistoryStore
    @ObservedObject private var settings: SettingsStore
    // Observed, not snapshotted into AttentionAction: accepting or denying a
    // suggestion must update the stack while the popover is still open.
    @ObservedObject private var learner: CorrectionLearner

    let attentionActions: [AttentionAction]
    /// Whether a permission Aloud needs is missing *and* setup is finished —
    /// decided by the delegate so this view has one source of truth for it,
    /// and so the preview harness can stage the state on a Mac where
    /// everything happens to be granted.
    let permissionMissing: Bool
    let scratchpadVisible: Bool
    let onOpenHistory: () -> Void
    let onOpenSettings: () -> Void
    let onToggleScratchpad: () -> Void
    let onCopyLast: () -> Void
    let onRetryLast: () -> Void
    let onUseExactWords: () -> Void
    let onQuit: () -> Void

    init(controller: DictationController,
         learner: CorrectionLearner,
         attentionActions: [AttentionAction],
         permissionMissing: Bool,
         scratchpadVisible: Bool,
         onOpenHistory: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void,
         onToggleScratchpad: @escaping () -> Void,
         onCopyLast: @escaping () -> Void,
         onRetryLast: @escaping () -> Void,
         onUseExactWords: @escaping () -> Void,
         onQuit: @escaping () -> Void) {
        self.controller = controller
        _history = ObservedObject(wrappedValue: controller.history)
        _settings = ObservedObject(wrappedValue: controller.settings)
        _learner = ObservedObject(wrappedValue: learner)
        self.attentionActions = attentionActions
        self.permissionMissing = permissionMissing
        self.scratchpadVisible = scratchpadVisible
        self.onOpenHistory = onOpenHistory
        self.onOpenSettings = onOpenSettings
        self.onToggleScratchpad = onToggleScratchpad
        self.onCopyLast = onCopyLast
        self.onRetryLast = onRetryLast
        self.onUseExactWords = onUseExactWords
        self.onQuit = onQuit
    }

    /// Rows shown in the popover; the full list lives in Settings → History.
    private static let maxVisibleEntries = 30

    /// Tallest the history list gets before it scrolls instead of growing.
    private static let maxHistoryHeight: CGFloat = 320

    @State private var historyContentHeight: CGFloat = 0

    // Whether the grouped suggestions are open for review in their own popover.
    @State private var reviewingSuggestions = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if showsAttention {
                attention
                Divider()
            }

            quickActions
            historyHeader
            historyContent
            Divider()
            footer
        }
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: pendingSuggestions.isEmpty) { _, empty in
            if empty { reviewingSuggestions = false }
        }
        // Answering the last question closes the review; the menu behind it
        // must go back to closing on its own the moment it does.
        .onChange(of: reviewingSuggestions) { _, shown in
            NotificationCenter.default.post(name: .aloudStatusMenuModal, object: shown)
        }
        .onDisappear {
            if reviewingSuggestions {
                NotificationCenter.default.post(name: .aloudStatusMenuModal, object: false)
            }
        }
    }

    // Suggestions awaiting an answer. Hidden while the feature is switched
    // off — the stored pairs stay put, but the questions go quiet with it.
    private var pendingSuggestions: [CorrectionLearner.Suggestion] {
        settings.learnCorrections ? learner.readySuggestions : []
    }

    // Whether anything sits above the quick actions — which decides whether
    // they need their own top inset: the header brings its own breathing
    // room, a divider does not.
    private var showsAttention: Bool {
        !attentionActions.isEmpty || !pendingSuggestions.isEmpty
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: statusSymbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, isActive: controller.phase == .recording)
                .frame(width: 34, height: 34)
                .background(statusColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Aloud")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            cleanUpMenu

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .help(loc("Settings"))
            .accessibilityLabel(loc("Settings"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var attention: some View {
        VStack(spacing: 6) {
            ForEach(attentionActions) { item in
                Button(action: item.action) {
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol)
                            .frame(width: 18)
                            .foregroundStyle(item.tone == .warning ? Color.orange : Color.primary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .lineLimit(1)
                            if let detail = item.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 6)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(StatusMenuAttentionButtonStyle(tone: item.tone))
            }
            suggestionCells
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: pendingSuggestions)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: reviewingSuggestions)
    }

    // Suggestion cells share the attention stack but read as a different kind
    // of thing: an attention row is a shortcut, a suggestion is a question —
    // no chevron, two answers, and it stays until one of them is given.
    @ViewBuilder
    private var suggestionCells: some View {
        let pending = pendingSuggestions
        if pending.count >= 3 {
            // Past a couple of questions the stack would crowd the menu, so
            // they collapse to one row that opens the lot in a popover of its
            // own — the menu keeps its size, and the review arrives as its own
            // small panel rather than by shoving everything below it down.
            SuggestionSummaryCell(count: pending.count) { reviewingSuggestions = true }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .popover(isPresented: $reviewingSuggestions, arrowEdge: .bottom) {
                    SuggestionReviewPopover(
                        suggestions: pending,
                        onAccept: acceptSuggestion,
                        onDeny: denySuggestion,
                        onAcceptAll: { for s in pending { learner.accept(s, settings: settings) } },
                        onDenyAll: { for s in pending { learner.dismiss(s) } }
                    )
                }
        } else {
            ForEach(pending) { suggestion in
                SuggestionCell(suggestion: suggestion,
                               onAccept: { acceptSuggestion(suggestion) },
                               onDeny: { denySuggestion(suggestion) })
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
    }

    private func acceptSuggestion(_ suggestion: CorrectionLearner.Suggestion) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            learner.accept(suggestion, settings: settings)
        }
    }

    private func denySuggestion(_ suggestion: CorrectionLearner.Suggestion) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            learner.dismiss(suggestion)
        }
    }

    /// Clean-up is the one setting people change by the task rather than once:
    /// exact words for a command, tightened prose for an email. Settings owns
    /// the full segmented picker — at 360pt that control eats the popover — so
    /// this is a bare pop-up: the level's name, in the level's colour, with the
    /// chevron that says it opens. No bezel, so it sits in the header beside
    /// the gear without reading as a second button competing with it.
    private var cleanUpMenu: some View {
        Menu {
            // Inline picker inside the menu, not four Buttons: the checkmark
            // beside the current level comes free and behaves like every other
            // macOS pop-up.
            Picker(loc("Clean-up"), selection: $settings.polishLevel) {
                ForEach(controller.availableLevels) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 3) {
                // Concise with no rewrite engine quietly behaves as Standard;
                // say so rather than promise a tightening that never comes.
                if settings.polishLevel == .concise, !controller.enhancerAvailable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text(settings.polishLevel.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(cleanUpTint)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(cleanUpHelp)
        .accessibilityLabel(loc("Clean-up: %@", settings.polishLevel.displayName))
        .accessibilityHint(settings.polishLevel.shortSummary)
    }

    /// A colour per level, so the current one is recognised before it's read.
    /// The ramp tracks how much Aloud touches the words — grey for untouched,
    /// Aloud's own blue for the default, purple where a model gets involved —
    /// and deliberately skips orange and red, which this popover already spends
    /// on things being wrong.
    private var cleanUpTint: Color {
        switch settings.polishLevel {
        case .off: return .gray
        case .light: return .teal
        case .standard: return .aloud
        case .concise: return .purple
        }
    }

    /// The hover text is the whole explanation: with no label and no ⓘ, this is
    /// where "what does Concise actually do" gets answered short of opening
    /// Settings. The unavailable-rewrite case says so instead — that fact
    /// matters more than the level's promise, which isn't being kept.
    private var cleanUpHelp: String {
        if settings.polishLevel == .concise, !controller.enhancerAvailable {
            return loc("The rewrite engine isn’t available right now — Standard clean-up is used instead.")
        }
        return loc("Clean-up: %@", settings.polishLevel.explanation)
    }

    private var quickActionItems: [QuickAction] {
        var items: [QuickAction] = []
        if !controller.lastTranscription.isEmpty {
            items.append(.init(id: "copy",
                               title: loc("Copy Last"),
                               help: loc("Copy Last Text"),
                               symbol: "doc.on.doc",
                               action: onCopyLast))
        }
        if controller.retryAvailable {
            items.append(.init(id: "retry",
                               title: loc("Type Again"),
                               help: loc("Type It Again"),
                               symbol: "arrow.clockwise",
                               action: onRetryLast))
        }
        if controller.undoEnhancementAvailable {
            items.append(.init(id: "exact",
                               title: loc("Exact Words"),
                               help: loc("Use Exact Words"),
                               symbol: "arrow.uturn.backward",
                               action: onUseExactWords))
        }
        return items
    }

    @ViewBuilder
    private var quickActions: some View {
        let items = quickActionItems
        if !items.isEmpty {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    Button(action: item.action) {
                        Label(item.title, systemImage: item.symbol)
                            .labelStyle(.titleAndIcon)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            // A longer translation shrinks rather than
                            // truncating: three of these have to share 360pt.
                            .minimumScaleFactor(0.75)
                    }
                    .buttonStyle(StatusMenuQuickActionButtonStyle())
                    .help(item.help)
                    .accessibilityLabel(item.help)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, showsAttention ? 10 : 0)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private var historyHeader: some View {
        if !history.entries.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(loc("Recent Dictations"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                // The full list — search, editing, everything older than the
                // handful shown here — lives in Settings → History. Naming it
                // at the top of the list is where someone looks when the row
                // they want isn't in view.
                Button(action: onOpenHistory) {
                    HStack(spacing: 2) {
                        Text(loc("All History"))
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.aloud)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(loc("All History"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if history.entries.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(loc("No Dictations Yet"))
                    .font(.subheadline.weight(.medium))
                Text(loc("Recent dictations appear here. They stay on this Mac."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 44)
            .padding(.vertical, 22)
        } else {
            let visible = Array(history.entries.prefix(Self.maxVisibleEntries))
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(visible) { entry in
                        RecentDictationRow(entry: entry)
                        if entry.id != visible.last?.id {
                            Divider()
                                .padding(.leading, 42)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: HistoryHeightKey.self,
                                               value: proxy.size.height)
                    }
                )
            }
            .onPreferenceChange(HistoryHeightKey.self) { historyContentHeight = $0 }
            .frame(height: min(max(historyContentHeight, 1), Self.maxHistoryHeight))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: onToggleScratchpad) {
                Label(loc("Scratchpad"), systemImage: "note.text")
            }
            .buttonStyle(.borderless)

            Spacer()

            Button(action: onQuit) {
                Label(loc("Quit Aloud"), systemImage: "power")
            }
            .buttonStyle(.borderless)
            .help(loc("Quit Aloud"))
            .accessibilityLabel(loc("Quit Aloud"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .overlay(alignment: .leading) {
            if scratchpadVisible {
                Circle()
                    .fill(Color.aloud)
                    .frame(width: 5, height: 5)
                    .offset(x: 7)
            }
        }
    }

    private var statusSymbol: String {
        if permissionMissing { return "exclamationmark.triangle.fill" }
        switch controller.phase {
        case .recording: return "waveform.badge.mic"
        case .transcribing: return "waveform.badge.magnifyingglass"
        case .error: return "waveform.badge.exclamationmark"
        case .idle: return "waveform"
        }
    }

    private var statusColor: Color {
        if permissionMissing { return .orange }
        switch controller.phase {
        case .error: return .orange
        default: return .aloud
        }
    }

    private var statusText: String {
        // Before setup is finished, missing permissions aren't news — they're
        // what the walkthrough is for. Saying "microphone access needed" to
        // someone who hasn't been asked yet reads as a fault, not a step.
        if !settings.onboardingComplete { return loc("Finish setting up Aloud") }
        if permissionMissing {
            return Permissions.microphone != .granted
                ? loc("Microphone access needed")
                : loc("Accessibility access needed")
        }
        switch controller.phase {
        case .recording:
            return loc("Listening…")
        case .transcribing:
            return loc("One moment…")
        case .error(let message):
            return message
        case .idle:
            break
        }
        switch controller.transcriberState {
        case .modelMissing: return loc("Voice setup needed")
        case .downloading(let progress):
            return loc("Downloading voice recognition… %ld%%", Int(progress * 100))
        case .loading: return loc("Warming up…")
        case .failed: return loc("Voice download didn’t finish")
        case .ready:
            if settings.onboardingComplete, !controller.isListening {
                return loc("Dictation key isn’t working — try reopening Aloud")
            }
            return loc("Hold %@ to dictate", settings.hotkey.displayName)
        }
    }
}

private struct HistoryHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct StatusMenuAttentionButtonStyle: ButtonStyle {
    let tone: StatusMenuView.AttentionAction.Tone

    @Environment(\.isEnabled) private var isEnabled

    // Warnings get orange, and an outline the invitations don't have — the
    // tinted fill alone is easy to read as decoration, where a bounded card
    // asks to be dealt with.
    private var accent: Color { tone == .warning ? .orange : .aloud }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                accent.opacity(configuration.isPressed ? 0.22 : (tone == .warning ? 0.14 : 0.09)),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                if tone == .warning {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(accent.opacity(0.45), lineWidth: 1)
                }
            }
    }
}

/// Compact capsule for the last-dictation actions. Quieter than an attention
/// card — nothing here is wrong, these are just fast paths — but still a
/// visible target rather than a menu item nobody opens.
private struct StatusMenuQuickActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07),
                in: Capsule(style: .continuous)
            )
            .contentShape(Capsule(style: .continuous))
    }
}

// One pending fix, asked as a question: what Aloud typed, what the user keeps
// changing it to, and two answers. Accepting acknowledges in place — the wand
// becomes a checkmark and holds for a beat — before the cell leaves the stack,
// so the click reads as "done", never "gone".
private struct SuggestionCell: View {
    let suggestion: CorrectionLearner.Suggestion
    let onAccept: () -> Void
    let onDeny: () -> Void

    @State private var accepted = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: accepted ? "checkmark.circle.fill" : "wand.and.sparkles")
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(Color.aloud)
                .frame(width: 18)
            SuggestionPhrase(from: suggestion.from, to: suggestion.to)
            Spacer(minLength: 8)
            SuggestionAnswerButtons(accepted: $accepted, showsCheckWhenAccepted: false,
                                    onAccept: onAccept, onDeny: onDeny)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Color.aloud.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.aloud.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(loc("Type “%1$@” instead of “%2$@”", suggestion.to, suggestion.from))
    }
}

// The fix itself, in the vocabulary of MappingRow: what Aloud typed reads
// quietly, what it should have been carries the weight.
private struct SuggestionPhrase: View {
    let from: String
    let to: String

    var body: some View {
        HStack(spacing: 5) {
            Text(from)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(to)
                .fontWeight(.medium)
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }
}

// The two answers, sized like the copy button on a history row. Accept flips
// the row into its acknowledged state and holds it on screen for a beat
// before the actual removal runs — an instant vanish makes the user wonder
// which button they hit.
private struct SuggestionAnswerButtons: View {
    @Binding var accepted: Bool
    // Rows without their own status glyph show the checkmark moment here.
    let showsCheckWhenAccepted: Bool
    let onAccept: () -> Void
    let onDeny: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if accepted {
                if showsCheckWhenAccepted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.aloud)
                        .frame(width: 24, height: 24)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            } else {
                answer("checkmark", tint: Color.aloud,
                       help: loc("Fix it automatically next time"), action: accept)
                answer("xmark", tint: Color.secondary,
                       help: loc("Never suggest this fix"), action: onDeny)
            }
        }
    }

    private func answer(_ symbol: String, tint: Color, help: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .frame(width: 24, height: 24)
                .foregroundStyle(tint)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    private func accept() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { accepted = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(550))
            onAccept()
        }
    }
}

// Three or more pending fixes as one row — the stack must never grow into a
// wall of questions. The row only announces them and opens the review; the
// menu keeps the size it had.
private struct SuggestionSummaryCell: View {
    let count: Int
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 9) {
                Image(systemName: "wand.and.sparkles")
                    .foregroundStyle(Color.aloud)
                    .frame(width: 18)
                Text(loc("%ld suggested fixes", count))
                    .font(.callout.weight(.medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(
            Color.aloud.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.aloud.opacity(0.25), lineWidth: 1)
        )
        .accessibilityLabel(loc("Review %ld suggested fixes", count))
    }
}

// The review itself, in a panel of its own — same quiet popover Settings uses
// for a dictation's original text. Answers can be given one at a time or to
// the whole list at once; the panel closes itself when none are left.
private struct SuggestionReviewPopover: View {
    let suggestions: [CorrectionLearner.Suggestion]
    let onAccept: (CorrectionLearner.Suggestion) -> Void
    let onDeny: (CorrectionLearner.Suggestion) -> Void
    let onAcceptAll: () -> Void
    let onDenyAll: () -> Void

    // Tall lists scroll rather than growing a panel taller than the menu.
    private static let maxListHeight: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc("Suggested Fixes"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(loc("Aloud noticed these corrections. Accepting one fixes that word automatically from now on."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(suggestions) { suggestion in
                        SuggestionReviewRow(suggestion: suggestion,
                                            onAccept: { onAccept(suggestion) },
                                            onDeny: { onDeny(suggestion) })
                        if suggestion.id != suggestions.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: Self.maxListHeight)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Button(loc("Deny All"), action: onDenyAll)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(loc("Accept All"), action: onAcceptAll)
                    .foregroundStyle(Color.aloud)
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.medium))
        }
        .frame(width: 300, alignment: .leading)
        .padding(14)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: suggestions)
    }
}

// A single fix inside the review: the same question as a standalone cell,
// minus the card chrome the panel already provides.
private struct SuggestionReviewRow: View {
    let suggestion: CorrectionLearner.Suggestion
    let onAccept: () -> Void
    let onDeny: () -> Void

    @State private var accepted = false

    var body: some View {
        HStack(spacing: 9) {
            SuggestionPhrase(from: suggestion.from, to: suggestion.to)
            Spacer(minLength: 8)
            SuggestionAnswerButtons(accepted: $accepted, showsCheckWhenAccepted: true,
                                    onAccept: onAccept, onDeny: onDeny)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: accepted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(loc("Type “%1$@” instead of “%2$@”", suggestion.to, suggestion.from))
    }
}

private struct RecentDictationRow: View {
    let entry: HistoryEntry

    @State private var hovering = false
    @State private var copied = false
    @FocusState private var copyFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DictationAppIcon(bundleID: entry.appBundleID)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(entry.appName ?? "Aloud")
                        .font(.caption.weight(.medium))
                    Text(verbatim: "·")
                        .foregroundStyle(.tertiary)
                    TimelineView(.periodic(from: entry.date, by: 60)) { context in
                        Text(HistoryRow.relativeLabel(for: entry.date, now: context.date))
                    }
                    .foregroundStyle(.secondary)
                }
                .lineLimit(1)

                Text(entry.text)
                    .font(.callout)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(copied ? Color.aloud : Color.secondary)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.borderless)
            .focused($copyFocused)
            .opacity(hovering || copyFocused || copied ? 1 : 0)
            .allowsHitTesting(hovering || copyFocused || copied)
            .help(copied ? loc("Copied") : loc("Copy"))
            .accessibilityLabel(copied ? loc("Copied") : loc("Copy"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(
            hovering ? Color.primary.opacity(0.045) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(loc("Copy"), action: copy)
            if let raw = entry.rawText {
                Button(loc("Copy Original")) {
                    copyToPasteboard(raw)
                }
            }
        }
    }

    private func copy() {
        copyToPasteboard(entry.text)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

private struct DictationAppIcon: View {
    let bundleID: String?

    var body: some View {
        Group {
            if let image = applicationIcon {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "text.quote")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityHidden(true)
    }

    private var applicationIcon: NSImage? {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

#Preview {
    StatusMenuView(controller: DictationController(),
                   learner: CorrectionLearner.shared,
                   attentionActions: [],
                   permissionMissing: false,
                   scratchpadVisible: false,
                   onOpenHistory: {},
                   onOpenSettings: {},
                   onToggleScratchpad: {},
                   onCopyLast: {},
                   onRetryLast: {},
                   onUseExactWords: {},
                   onQuit: {})
}
