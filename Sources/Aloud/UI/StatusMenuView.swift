import AppKit
import SwiftUI

/// A data-rich status item popover. A regular NSMenu is right for commands,
/// but recent dictations are content: they need readable text, scrolling, and
/// contextual actions without turning every transcript into a submenu.
struct StatusMenuView: View {
    struct AttentionAction: Identifiable {
        let id: String
        let title: String
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

    // Three or more pending suggestions collapse into one cell that expands
    // into a review list. Once open, the list stays a list even as answers
    // bring the count under the collapse threshold — mid-review the rows must
    // not reshuffle into standalone cells under the pointer.
    @State private var reviewingSuggestions = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if !attentionActions.isEmpty || !pendingSuggestions.isEmpty {
                attention
                Divider()
            }

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
    }

    // Suggestions awaiting an answer. Hidden while the feature is switched
    // off — the stored pairs stay put, but the questions go quiet with it.
    private var pendingSuggestions: [CorrectionLearner.Suggestion] {
        settings.learnCorrections ? learner.readySuggestions : []
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
                        Text(item.title)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(StatusMenuAttentionButtonStyle())
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
        if pending.count >= 3 || (reviewingSuggestions && !pending.isEmpty) {
            SuggestionReviewCell(
                suggestions: pending,
                expanded: $reviewingSuggestions,
                onAccept: acceptSuggestion,
                onDeny: denySuggestion,
                onAcceptAll: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        for s in pending { learner.accept(s, settings: settings) }
                    }
                },
                onDenyAll: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        for s in pending { learner.dismiss(s) }
                    }
                }
            )
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
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

    @ViewBuilder
    private var historyHeader: some View {
        if !history.entries.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(loc("Recent Dictations"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
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

            Menu {
                if !controller.lastTranscription.isEmpty {
                    Button(loc("Copy Last Text"), action: onCopyLast)
                }
                if controller.retryAvailable {
                    Button(loc("Type It Again"), action: onRetryLast)
                }
                if controller.undoEnhancementAvailable {
                    Button(loc("Use Exact Words"), action: onUseExactWords)
                }
                if !controller.lastTranscription.isEmpty
                    || controller.retryAvailable
                    || controller.undoEnhancementAvailable {
                    Divider()
                }
                Button(loc("History"), action: onOpenHistory)
                Button(loc("Settings"), action: onOpenSettings)
                Button(loc("Quit Aloud"), action: onQuit)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(loc("More"))
            .accessibilityLabel(loc("More"))
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
        switch controller.phase {
        case .recording: return "waveform.badge.mic"
        case .transcribing: return "waveform.badge.magnifyingglass"
        case .error: return "exclamationmark.waveform"
        case .idle: return "waveform"
        }
    }

    private var statusColor: Color {
        switch controller.phase {
        case .error: return .orange
        default: return .aloud
        }
    }

    private var statusText: String {
        if Permissions.microphone != .granted { return loc("Microphone access needed") }
        if Permissions.accessibility != .granted { return loc("Accessibility access needed") }
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
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Color.aloud.opacity(configuration.isPressed ? 0.16 : 0.09),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
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

// Three or more pending fixes as one cell — the stack must never grow into a
// wall of questions. Expanding it in place keeps the review where the
// suggestions already live; a sheet over a transient popover fights the
// popover's own dismissal.
private struct SuggestionReviewCell: View {
    let suggestions: [CorrectionLearner.Suggestion]
    @Binding var expanded: Bool
    let onAccept: (CorrectionLearner.Suggestion) -> Void
    let onDeny: (CorrectionLearner.Suggestion) -> Void
    let onAcceptAll: () -> Void
    let onDenyAll: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "wand.and.sparkles")
                        .foregroundStyle(Color.aloud)
                        .frame(width: 18)
                    Text(loc("%ld suggested fixes", suggestions.count))
                        .font(.callout.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if expanded {
                Divider()
                    .padding(.horizontal, 10)
                VStack(spacing: 0) {
                    ForEach(suggestions) { suggestion in
                        SuggestionReviewRow(suggestion: suggestion,
                                            onAccept: { onAccept(suggestion) },
                                            onDeny: { onDeny(suggestion) })
                        if suggestion.id != suggestions.last?.id {
                            Divider()
                                .padding(.leading, 10)
                        }
                    }
                }
                Divider()
                    .padding(.horizontal, 10)
                HStack {
                    Button(loc("Deny All"), action: onDenyAll)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(loc("Accept All"), action: onAcceptAll)
                        .foregroundStyle(Color.aloud)
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(
            Color.aloud.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.aloud.opacity(0.25), lineWidth: 1)
        )
    }
}

// A single fix inside the expanded review: the same question as a standalone
// cell, minus the card chrome the container already provides.
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
