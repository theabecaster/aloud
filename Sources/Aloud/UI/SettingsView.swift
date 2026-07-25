import SwiftUI

// One calm window, System Settings-style sidebar. Eight panes in three
// clusters: how Aloud runs (General, Keys, Dictation), what it does with your
// words (Vocabulary, Snippets, App Rules), and the record (History, About).
// Every pane answers one question, so nothing needs a second glance.
struct SettingsView: View {
    @ObservedObject var controller: DictationController
    // Watched here too: the sidebar dims a pane when the clean-up level makes
    // its contents inert, and that lives on the settings store.
    @ObservedObject private var settings: SettingsStore

    init(controller: DictationController) {
        self.controller = controller
        _settings = ObservedObject(wrappedValue: controller.settings)
    }

    enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case keys = "Keys"
        case dictation = "Dictation"
        case vocabulary = "Vocabulary"
        case snippets = "Snippets"
        case appRules = "App Rules"
        case history = "History"
        case about = "About"
        var id: String { rawValue }
        var title: String { loc(rawValue) }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .keys: return "keyboard"
            case .dictation: return "waveform"
            case .vocabulary: return "character.book.closed"
            case .snippets: return "text.insert"
            case .appRules: return "macwindow"
            case .history: return "clock"
            case .about: return "info.circle"
            }
        }
    }

    @State private var section: Section = .general

    // Headerless clusters: the grouping reads as rhythm in the sidebar
    // without inventing category names the user has to learn.
    private let clusters: [[Section]] = [
        [.general, .keys, .dictation],
        [.vocabulary, .snippets, .appRules],
        [.history, .about],
    ]

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(clusters.indices, id: \.self) { i in
                    SwiftUI.Section {
                        ForEach(clusters[i]) { s in
                            sidebarRow(s).tag(s)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 158, ideal: 168, max: 200)
        } detail: {
            switch section {
            case .general: GeneralSettings(controller: controller)
            case .keys: KeysSettings(controller: controller)
            case .dictation: DictationSettings(controller: controller)
            case .vocabulary: VocabularySettings(settings: controller.settings)
            case .snippets: SnippetsSettings(settings: controller.settings)
            case .appRules: AppRulesSettings(settings: controller.settings)
            case .history: HistorySettings(history: controller.history, settings: controller.settings)
            case .about: AboutSettings()
            }
        }
        .frame(minWidth: 680, idealWidth: 700, maxWidth: 900,
               minHeight: 460, idealHeight: 520, maxHeight: 900)
        .overlay(alignment: .top) {
            if controller.showSettingsStopBanner {
                Label(loc("Stopped listening so you can change settings"), systemImage: "mic.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: controller.showSettingsStopBanner)
    }

    // A pane whose contents currently do nothing reads as dimmed, with the
    // reason a hover away — still selectable, because the fix lives inside it.
    @ViewBuilder
    private func sidebarRow(_ s: Section) -> some View {
        if s == .vocabulary, !settings.polishLevel.appliesVocabulary {
            HStack(spacing: 0) {
                Label(s.title, systemImage: s.symbol)
                Spacer(minLength: 6)
                Image(systemName: "exclamationmark.circle")
                    .imageScale(.small)
            }
            .foregroundStyle(.secondary)
            .help(loc("Not in use — Clean-up is set to %@.", settings.polishLevel.displayName))
        } else {
            Label(s.title, systemImage: s.symbol)
        }
    }
}

// MARK: - General

// The app-level basics: is Aloud allowed to work, which mic, does it announce
// itself, does it start with the Mac.
struct GeneralSettings: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var settings: SettingsStore
    @State private var launchAtLogin: Bool
    @State private var devices: [AudioInputDevice] = []
    @State private var micAccess = Permissions.microphone
    @State private var axAccess = Permissions.accessibility

    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    init(controller: DictationController) {
        self.controller = controller
        self.settings = controller.settings
        _launchAtLogin = State(initialValue: LoginItem.isEnabled)
    }

    private var allGranted: Bool { micAccess == .granted && axAccess == .granted }

    var body: some View {
        Form {
            SwiftUI.Section {
                permissionRow(loc("Microphone access"),
                              granted: micAccess == .granted,
                              action: Permissions.openMicrophoneSettings)
                permissionRow(loc("Accessibility access"),
                              granted: axAccess == .granted,
                              action: Permissions.openAccessibilitySettings)
            } header: {
                Text(loc("Permissions"))
            } footer: {
                if !allGranted {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(loc("Without both, Aloud can’t hear you or type for you."))
                        // macOS routinely keeps a stale Accessibility entry
                        // after an app update: the switch reads on while the
                        // app isn't trusted. Name the fix instead of leaving
                        // the user staring at a switch that looks correct —
                        // but only for someone who had it working once, since
                        // for anyone else the switch really is just off.
                        if axAccess != .granted, settings.onboardingComplete {
                            Text(loc("Switch already on? Turn it off and on again — macOS keeps a stale entry after an update."))
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            SwiftUI.Section {
                Picker(loc("Microphone"), selection: micSelection) {
                    Text(loc("System default")).tag(nil as String?)
                    ForEach(devices) { d in
                        Text(d.name).tag(d.uid as String?)
                    }
                }
                Toggle(loc("Sound when recording starts"), isOn: $settings.soundCues)
            }

            SwiftUI.Section {
                Toggle(loc("Open Aloud at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        if LoginItem.setEnabled(on) {
                            settings.launchAtLogin = on
                        } else {
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                    .disabled(!LoginItem.isSupported)
            }
        }
        .formStyle(.grouped)
        .onAppear { devices = AudioDevices.inputDevices() }
        .onReceive(poll) { _ in
            micAccess = Permissions.microphone
            axAccess = Permissions.accessibility
        }
    }

    // Reassurance when it's on, a way out when it isn't — nothing in between.
    private func permissionRow(_ title: String, granted: Bool,
                               action: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            if granted {
                Label(loc("Allowed"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button(loc("Open Settings"), action: action)
            }
        }
    }

    private var micSelection: Binding<String?> {
        Binding(get: { settings.microphoneUID },
                set: { settings.microphoneUID = $0 })
    }
}

// MARK: - Keys

// Every key Aloud listens for, in one place. The hands-free switch and the
// hands-free key live together here; splitting them across panes was the
// single most confusing thing about the old layout.
struct KeysSettings: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var settings: SettingsStore

    init(controller: DictationController) {
        self.controller = controller
        _settings = ObservedObject(wrappedValue: controller.settings)
    }

    // Which recorder is shaking, and the sentence explaining why. One at a
    // time: the user can only be pressing one key.
    @State private var refusedSlot: KeySlot?
    @State private var refusedMessage = ""
    @State private var shake: CGFloat = 0

    var body: some View {
        Form {
            SwiftUI.Section {
                LabeledContent(loc("Dictation key")) {
                    HotkeyRecorderView(hotkey: settings.hotkey) { new in
                        assign(new, to: .dictation) { controller.updateHotkey($0) }
                    }
                    .shaking(refusedSlot == .dictation ? shake : 0)
                }
            } footer: {
                footnote(for: .dictation,
                         loc("Hold %@ to talk, release to type. Esc while holding cancels. Extra mouse buttons work too.",
                             settings.hotkey.displayName))
            }

            SwiftUI.Section {
                Toggle(loc("Hands-free mode"), isOn: $settings.handsFree)
                if settings.handsFree {
                    LabeledContent(loc("Hands-free key")) {
                        HStack(spacing: 6) {
                            OptionalHotkeyRecorderView(hotkey: settings.handsFreeHotkey) { new in
                                assign(new, to: .handsFree) { settings.handsFreeHotkey = $0 }
                            }
                            .shaking(refusedSlot == .handsFree ? shake : 0)
                            if settings.handsFreeHotkey != nil {
                                clearButton(loc("Remove the hands-free key")) {
                                    settings.handsFreeHotkey = nil
                                }
                            }
                        }
                    }
                }
            } footer: {
                // Three states, three sentences: the footer describes the keys
                // the user actually has, never a hypothetical one.
                footnote(for: .handsFree, handsFreeFooter)
            }

            // Only on Macs with the on-device engine — elsewhere the row
            // would record a key that can never do anything.
            if controller.commandsAvailable {
                SwiftUI.Section {
                    LabeledContent(loc("Command key")) {
                        HStack(spacing: 6) {
                            OptionalHotkeyRecorderView(hotkey: settings.commandHotkey) { new in
                                assign(new, to: .command) { settings.commandHotkey = $0 }
                            }
                            .shaking(refusedSlot == .command ? shake : 0)
                            if settings.commandHotkey != nil {
                                clearButton(loc("Remove the command key")) {
                                    settings.commandHotkey = nil
                                }
                            }
                        }
                    }
                } footer: {
                    footnote(for: .command, settings.commandHotkey.map {
                        loc("Hold %@ and say what to do: rewrite or translate the selected text, or write something new at the cursor.",
                            $0.displayName)
                    } ?? loc("Optional. Pick a key, then hold it and say what to do: rewrite or translate the selected text, or write something new at the cursor."))
                }
            }
        }
        .formStyle(.grouped)
    }

    // The three keys Aloud listens for. Two of them doing the same thing means
    // one silently never fires, so a repeat is refused at the moment of choice.
    private enum KeySlot { case dictation, handsFree, command
        var name: String {
            switch self {
            case .dictation: return loc("dictation key")
            case .handsFree: return loc("hands-free key")
            case .command: return loc("command key")
            }
        }
    }

    private func holder(of hotkey: Hotkey) -> KeySlot? {
        if settings.hotkey == hotkey { return .dictation }
        if settings.handsFreeHotkey == hotkey { return .handsFree }
        if controller.commandsAvailable, settings.commandHotkey == hotkey { return .command }
        return nil
    }

    private func assign(_ hotkey: Hotkey, to slot: KeySlot, commit: (Hotkey) -> Void) {
        guard let taken = holder(of: hotkey), taken != slot else {
            refusedSlot = nil
            commit(hotkey)
            return
        }
        // Refused: shake the recorder that asked, say who already owns the key,
        // and leave the old assignment untouched.
        refusedMessage = loc("%1$@ is already your %2$@.", hotkey.displayName, taken.name)
        refusedSlot = slot
        NSSound.beep()
        shake = 0
        withAnimation(.linear(duration: 0.35)) { shake = 1 }
        Task {
            // Park the effect back at zero (sin ends where it began, so this
            // is invisible) so the next refusal animates from a clean start.
            try? await Task.sleep(for: .milliseconds(400))
            shake = 0
            try? await Task.sleep(for: .seconds(4))
            if refusedSlot == slot { withAnimation { refusedSlot = nil } }
        }
    }

    // The section's own footnote, or the refusal that replaces it while the
    // shake is still fresh in the eye.
    @ViewBuilder
    private func footnote(for slot: KeySlot, _ text: String) -> some View {
        if refusedSlot == slot {
            Label(refusedMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .transition(.opacity)
        } else {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // Describes the keys the user has right now: off, double-press, or the
    // dedicated key they picked.
    private var handsFreeFooter: String {
        guard settings.handsFree else {
            return loc("Off — %@ only listens while you hold it.", settings.hotkey.displayName)
        }
        guard let key = settings.handsFreeHotkey else {
            return loc("Double-press %@ to keep listening after you let go. Esc finishes and types everything.",
                       settings.hotkey.displayName)
        }
        return loc("Press %1$@ to start listening, then Esc — or %1$@ again — to finish and type. Double-pressing %2$@ still works.",
                   key.displayName, settings.hotkey.displayName)
    }

    private func clearButton(_ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Hotkey recorder

// The same refusal the login window uses: a short horizontal shake, no dialog
// to dismiss. Driven by a counter so every refusal animates, even a repeat.
private struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let swings = sin(animatableData * .pi * 3)
        return ProjectionTransform(CGAffineTransform(translationX: swings * 5, y: 0))
    }
}

private extension View {
    /// `progress` runs 0 → 1 for one refusal; both ends sit at zero offset.
    func shaking(_ progress: CGFloat) -> some View {
        modifier(ShakeEffect(animatableData: progress))
    }
}

// Click, then press the desired key (a lone modifier like right ⌥ counts).
struct HotkeyRecorderView: View {
    var hotkey: Hotkey
    var onChange: (Hotkey) -> Void
    @State private var recording = false

    var body: some View {
        Button {
            recording.toggle()
            if recording { KeyCaptureWindow.begin { captured in
                recording = false
                if let captured { onChange(captured) }
            } }
        } label: {
            Text(recording ? loc("Press a key…") : hotkey.displayName)
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
    }
}

// Same recorder for an optional slot — shows "None" until a key is set.
struct OptionalHotkeyRecorderView: View {
    var hotkey: Hotkey?
    var onChange: (Hotkey) -> Void
    @State private var recording = false

    var body: some View {
        Button {
            recording.toggle()
            if recording { KeyCaptureWindow.begin { captured in
                recording = false
                if let captured { onChange(captured) }
            } }
        } label: {
            Text(recording ? loc("Press a key…") : (hotkey?.displayName ?? loc("None")))
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
    }
}

// Captures the next key or lone-modifier press via a local event monitor.
@MainActor
enum KeyCaptureWindow {
    private static var monitor: Any?

    static func begin(completion: @escaping (Hotkey?) -> Void) {
        end()
        var lastFlags = NSEvent.modifierFlags
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .otherMouseDown]) { event in
            if event.type == .otherMouseDown {
                // Extra mouse buttons (3rd and up) can be push-to-talk keys.
                end()
                completion(Hotkey(keyCode: UInt16(clamping: event.buttonNumber),
                                  modifiers: 0, isModifierKey: false, isMouseButton: true))
                return nil
            }
            if event.type == .keyDown {
                if event.keyCode == 53 { // Esc cancels recording
                    end(); completion(nil); return nil
                }
                let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
                var cgFlags: UInt64 = 0
                if mods.contains(.command) { cgFlags |= CGEventFlags.maskCommand.rawValue }
                if mods.contains(.option) { cgFlags |= CGEventFlags.maskAlternate.rawValue }
                if mods.contains(.control) { cgFlags |= CGEventFlags.maskControl.rawValue }
                if mods.contains(.shift) { cgFlags |= CGEventFlags.maskShift.rawValue }
                end()
                completion(Hotkey(keyCode: event.keyCode, modifiers: cgFlags, isModifierKey: false))
                return nil
            } else {
                // A modifier released with no other key = lone-modifier hotkey.
                let now = event.modifierFlags
                let released = lastFlags.subtracting(now)
                lastFlags = now
                if !released.isEmpty {
                    let candidate = Hotkey(keyCode: event.keyCode, modifiers: 0, isModifierKey: true)
                    if candidate.modifierFlag != nil {
                        end()
                        completion(candidate)
                        return nil
                    }
                }
                return event
            }
        }
    }

    static func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Dictation

// What happens to your words between speaking and typing. Descriptions live
// in group footers, the way System Settings does it, so a toggle is a toggle
// and the explanation doesn't push the controls apart.
struct DictationSettings: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: SettingsStore
    @State private var showExperimentalInfo = false

    init(controller: DictationController) {
        self.controller = controller
        _settings = ObservedObject(wrappedValue: controller.settings)
    }

    // Languages not yet declared, offered alphabetically by their shown name.
    private var addableLanguages: [String] {
        DictationLanguages.supported
            .filter { !settings.declaredLanguages.contains($0) }
            .sorted { DictationLanguages.displayName($0) < DictationLanguages.displayName($1) }
    }

    var body: some View {
        Form {
            // Only present while a session would run at reduced accuracy —
            // shows how far along the one-time upgrade is.
            if controller.usingFallback {
                SwiftUI.Section {
                    switch controller.upgradeState {
                    case .downloading(let progress):
                        ProgressView(value: progress) {
                            Text(loc("Setting up full accuracy — %ld%%", Int(progress * 100)))
                        }
                    case .loading:
                        ProgressView {
                            Text(loc("Setting up full accuracy — almost done"))
                        }
                    default:
                        Label(loc("Waiting for internet to finish setting up full accuracy"), systemImage: "wifi.slash")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(loc("Basic dictation in use"))
                } footer: {
                    Text(loc("Dictation keeps working while this finishes; the switch is automatic."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            SwiftUI.Section {
                Picker(loc("Clean-up"), selection: $settings.polishLevel) {
                    ForEach(controller.availableLevels) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                if settings.polishLevel == .concise, !controller.enhancerAvailable {
                    Label(loc("The rewrite engine isn’t available right now — Standard clean-up is used instead."),
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(settings.polishLevel.explanation)
                    Text(loc("History always keeps your exact words."))
                        .foregroundStyle(.tertiary)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            SwiftUI.Section {
                ForEach(settings.declaredLanguages, id: \.self) { code in
                    HStack {
                        Text(DictationLanguages.displayName(code))
                        Spacer()
                        if settings.declaredLanguages.count > 1 {
                            Button {
                                settings.declaredLanguages.removeAll { $0 == code }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(loc("Remove this language"))
                        }
                    }
                }
                if !addableLanguages.isEmpty {
                    Menu {
                        ForEach(addableLanguages, id: \.self) { code in
                            Button(DictationLanguages.displayName(code)) {
                                settings.declaredLanguages.append(code)
                            }
                        }
                    } label: {
                        Label(loc("Add a Language"), systemImage: "plus")
                    }
                }
            } header: {
                Text(loc("Languages"))
            } footer: {
                Text(loc("Listing the languages you dictate in helps when a recording could be read more than one way."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section {
                Toggle(loc("Say “press enter” to send"), isOn: $settings.pressEnterCommand)
            } footer: {
                Text(loc("End a dictation with those words and Aloud presses Return after typing — handy in chat apps."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section {
                Toggle(loc("Live typing"), isOn: $settings.liveTyping)
            } header: {
                HStack(spacing: 5) {
                    Text(loc("Experimental"))
                    Button {
                        showExperimentalInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showExperimentalInfo, arrowEdge: .bottom) {
                        Text(loc("Experimental features work, but expect the occasional hiccup. You can turn them off any time."))
                            .font(.callout)
                            .frame(width: 250)
                            .padding(14)
                    }
                }
            } footer: {
                Text(settings.liveTyping
                     ? loc("Words appear as you speak and settle as Aloud hears more.")
                     : loc("Everything is typed at once when you release the key."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - List editor shell

// Vocabulary, Snippets, and App Rules are the same shape: a standing purpose
// line, the rules you've made, and one row to add another. They used to be
// three hand-rolled layouts; this is the one idiom they share.
struct ListEditorPane<Rows: View, Editor: View, Notice: View>: View {
    let title: String
    let purpose: String
    let isEmpty: Bool
    @ViewBuilder var rows: () -> Rows
    @ViewBuilder var editor: () -> Editor
    // Optional first card: why this pane's contents currently do nothing.
    @ViewBuilder var notice: () -> Notice

    // A grouped Form, like every other pane. Hand-rolled chrome (a header
    // Text over a greedy empty state, a bottom bar) fights NavigationSplitView
    // for width badly enough that the sidebar stops drawing.
    var body: some View {
        Form {
            notice()
            SwiftUI.Section {
                if isEmpty {
                    Text(loc("Nothing here yet — add one below."))
                        .foregroundStyle(.secondary)
                } else {
                    rows()
                }
            } header: {
                Text(title)
            } footer: {
                Text(purpose)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section {
                editor()
            }
        }
        .formStyle(.grouped)
    }
}

// Panes with nothing to explain skip the notice entirely.
extension ListEditorPane where Notice == EmptyView {
    init(title: String, purpose: String, isEmpty: Bool,
         @ViewBuilder rows: @escaping () -> Rows,
         @ViewBuilder editor: @escaping () -> Editor) {
        self.init(title: title, purpose: purpose, isEmpty: isEmpty,
                  rows: rows, editor: editor, notice: { EmptyView() })
    }
}

// One card, one sentence, one way out — the same shape as a Form row so the
// pane keeps its rhythm instead of growing a banner.
struct InactiveNotice: View {
    let message: String
    let actionLabel: String
    let action: () -> Void

    var body: some View {
        SwiftUI.Section {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(actionLabel, action: action)
            }
        }
    }
}

// The "you say X → Aloud does Y" row every editor pane shares.
struct MappingRow: View {
    let from: String
    let to: String
    var toLineLimit: Int = 1
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(from)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(to)
                .fontWeight(.medium)
                .lineLimit(toLineLimit)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(loc("Remove"))
        }
    }
}

// MARK: - Vocabulary

struct VocabularySettings: View {
    @ObservedObject var settings: SettingsStore
    @State private var newPattern = ""
    @State private var newReplacement = ""

    var body: some View {
        ListEditorPane(
            title: loc("Corrections"),
            purpose: loc("Words Aloud keeps getting wrong — a name, a product, a term of art. You can also add these from History with “Fix”."),
            isEmpty: settings.replacements.isEmpty
        ) {
            ForEach(settings.replacements) { r in
                MappingRow(from: r.pattern, to: r.replacement) {
                    settings.replacements.removeAll { $0.id == r.id }
                }
            }
        } editor: {
            // Bordered: in a Form a bare TextField draws no bezel, so the
            // row reads as static text with nowhere to type. The label stays
            // visible — it's the only thing naming what goes in the field.
            TextField(loc("Aloud types…"), text: $newPattern)
                .textFieldStyle(.roundedBorder)
            TextField(loc("It should be…"), text: $newReplacement)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(loc("Add"), action: add)
                    .disabled(!canAdd)
            }
        } notice: {
            // Corrections only run in the Standard pass. Saying so in the
            // footnote wasn't enough — a list that quietly does nothing needs
            // to say so where the eye lands, and offer the one-click cure.
            if !settings.polishLevel.appliesVocabulary {
                InactiveNotice(
                    message: loc("These words aren’t applied while Clean-up is %@.",
                                 settings.polishLevel.displayName),
                    actionLabel: loc("Use Standard")
                ) {
                    settings.polishLevel = .standard
                }
            }
        }
    }

    private var canAdd: Bool {
        !newPattern.trimmingCharacters(in: .whitespaces).isEmpty
            && !newReplacement.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func add() {
        let p = newPattern.trimmingCharacters(in: .whitespaces)
        let r = newReplacement.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !r.isEmpty else { return }
        settings.replacements.append(Replacement(pattern: p, replacement: r))
        newPattern = ""; newReplacement = ""
    }
}

// MARK: - Snippets

struct SnippetsSettings: View {
    @ObservedObject var settings: SettingsStore
    @State private var newTrigger = ""
    @State private var newExpansion = ""

    var body: some View {
        ListEditorPane(
            title: loc("Snippets"),
            purpose: loc("Say a short phrase as a whole dictation and Aloud types the long version — say “my email”, get your address."),
            isEmpty: settings.snippets.isEmpty
        ) {
            ForEach(settings.snippets) { s in
                MappingRow(from: "“\(s.trigger)”", to: s.expansion, toLineLimit: 2) {
                    settings.snippets.removeAll { $0.id == s.id }
                }
            }
        } editor: {
            TextField(loc("When you say…"), text: $newTrigger)
                .textFieldStyle(.roundedBorder)
            TextField(loc("Aloud types…"), text: $newExpansion)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(loc("Add"), action: add)
                    .disabled(!canAdd)
            }
        }
    }

    private var canAdd: Bool {
        !newTrigger.trimmingCharacters(in: .whitespaces).isEmpty
            && !newExpansion.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func add() {
        let t = newTrigger.trimmingCharacters(in: .whitespaces)
        let e = newExpansion.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !e.isEmpty else { return }
        settings.snippets.append(Snippet(trigger: t, expansion: e))
        newTrigger = ""; newExpansion = ""
    }
}

// MARK: - App Rules

// Per-app overrides for how the Concise rewrite behaves. Aloud already adapts
// to well-known chat, email, notes, and code apps on its own; a rule here
// beats that built-in choice for one specific app.
struct AppRulesSettings: View {
    @ObservedObject var settings: SettingsStore

    // What the behavior picker offers: a built-in category, the user's own
    // instruction, or the exact words.
    private enum BehaviorPick: Hashable {
        case category(DictationMode)
        case custom
        case verbatim
    }

    private static let otherAppTag = "~other"

    @State private var runningApps: [(name: String, bundleID: String)] = []
    @State private var appSelection = ""      // bundle ID, "" placeholder, or otherAppTag
    @State private var otherBundleID = ""
    @State private var behaviorPick: BehaviorPick = .verbatim
    @State private var customInstruction = ""

    var body: some View {
        ListEditorPane(
            title: loc("App Rules"),
            purpose: loc("Pin how Aloud writes in one app. Without a rule it adapts on its own — chat, email, notes, and code all read differently."),
            isEmpty: settings.appModes.isEmpty
        ) {
            ForEach(settings.appModes) { rule in
                MappingRow(from: rule.appName ?? rule.bundleID, to: rule.summary) {
                    settings.appModes.removeAll { $0.id == rule.id }
                }
                .help(rule.bundleID)
            }
        } editor: {
            Picker(loc("App"), selection: $appSelection) {
                Text(loc("Choose an app")).tag("")
                ForEach(runningApps, id: \.bundleID) { app in
                    Text(app.name).tag(app.bundleID)
                }
                Divider()
                Text(loc("Other app")).tag(Self.otherAppTag)
            }
            if appSelection == Self.otherAppTag {
                TextField(loc("Bundle ID, e.g. com.example.app"), text: $otherBundleID)
                    .textFieldStyle(.roundedBorder)
            }
            Picker(loc("Behavior"), selection: $behaviorPick) {
                Text(loc("Exact words")).tag(BehaviorPick.verbatim)
                Divider()
                ForEach(DictationMode.allCases) { mode in
                    Text(loc("%@ style", mode.displayName)).tag(BehaviorPick.category(mode))
                }
                Divider()
                Text(loc("Custom instruction")).tag(BehaviorPick.custom)
            }
            if behaviorPick == .custom {
                TextField(loc("How should it be written there? e.g. Warm and upbeat."),
                          text: $customInstruction)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button(loc("Add")) { addRule() }
                    .disabled(!canAdd)
            }
        }
        .onAppear { refreshRunningApps() }
    }

    private var chosenBundleID: String {
        appSelection == Self.otherAppTag
            ? otherBundleID.trimmingCharacters(in: .whitespaces)
            : appSelection
    }

    private var canAdd: Bool {
        guard !chosenBundleID.isEmpty else { return false }
        if behaviorPick == .custom,
           customInstruction.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    private func addRule() {
        let bundleID = chosenBundleID
        guard !bundleID.isEmpty else { return }
        let name = runningApps.first { $0.bundleID == bundleID }?.name
        let behavior: AppModeRule.Behavior
        switch behaviorPick {
        case .category(let mode): behavior = .category(mode)
        case .custom: behavior = .custom(customInstruction.trimmingCharacters(in: .whitespaces))
        case .verbatim: behavior = .verbatim
        }
        // One rule per app: adding again replaces the old choice.
        settings.appModes.removeAll { $0.bundleID.lowercased() == bundleID.lowercased() }
        settings.appModes.append(AppModeRule(appName: name, bundleID: bundleID, behavior: behavior))
        appSelection = ""
        otherBundleID = ""
        customInstruction = ""
    }

    private func refreshRunningApps() {
        var seen = Set<String>()
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, let name = app.localizedName,
                      id != Bundle.main.bundleIdentifier, seen.insert(id).inserted
                else { return nil }
                return (name: name, bundleID: id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - History

struct HistorySettings: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var settings: SettingsStore
    @State private var searchText = ""

    private var filtered: [HistoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return history.entries }
        return history.entries.filter { $0.matches(query) }
    }

    private var averageWPM: Int {
        guard settings.statsSeconds > 1 else { return 0 }
        return Int((Double(settings.statsWords) / (settings.statsSeconds / 60)).rounded())
    }

    var body: some View {
        VStack(spacing: 0) {
            // A zero is not an insight — only totals that exist get a block.
            let stats: [(value: Int, label: String)] = [
                (settings.statsWords, loc("words spoken")),
                (settings.statsDictations, loc("dictations")),
                (averageWPM, loc("words per minute")),
            ].filter { $0.0 > 0 }
            if !stats.isEmpty {
                HStack {
                    ForEach(stats.indices, id: \.self) { i in
                        if i > 0 { Divider().frame(height: 28) }
                        StatBlock(value: "\(stats[i].value)", label: stats[i].label)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                Divider()
            }
            if history.entries.isEmpty {
                ContentUnavailableView(loc("No Dictations Yet"),
                                       systemImage: "quote.bubble",
                                       description: Text(loc("Recent dictations appear here. They stay on this Mac.")))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(loc("Search dictations"), text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(filtered) { entry in
                        HistoryRow(entry: entry, settings: settings)
                    }
                    .scrollContentBackground(.hidden)
                }
                Divider()
                HStack {
                    Picker(loc("Keep"), selection: $settings.historyLimit) {
                        ForEach([25, 50, 100, 200], id: \.self) { n in
                            Text(loc("%ld dictations", n)).tag(n)
                        }
                    }
                    .fixedSize()
                    .onChange(of: settings.historyLimit) { _, limit in
                        history.trim(to: limit)
                    }
                    Spacer()
                    Button(loc("Clear History")) { history.clear() }
                }
                .padding(12)
            }
        }
    }
}

// One lifetime total, System Settings-toned: big number, quiet caption.
struct StatBlock: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    @ObservedObject var settings: SettingsStore
    @State private var showRaw = false
    @State private var showFix = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.text)
                .lineLimit(3)
            // Metadata yields, actions never do: the date and app name truncate
            // when the window is narrow so the buttons keep their full labels.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 5) {
                    // Minute resolution, not a live-ticking second counter:
                    // seconds spinning in every row pulled the eye off the text.
                    TimelineView(.periodic(from: entry.date, by: 60)) { context in
                        Text(Self.relativeLabel(for: entry.date, now: context.date))
                    }
                    if let app = entry.appName {
                        Text(verbatim: "·").foregroundStyle(.tertiary)
                        Text(app)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)

                Spacer(minLength: 8)

                HStack(spacing: 12) {
                    if let raw = entry.rawText {
                        // A quiet popover, like the ⓘ next to Experimental —
                        // inline expansion made rows jump around.
                        rowAction(loc("Show original"), symbol: "eye") { showRaw = true }
                            .popover(isPresented: $showRaw, arrowEdge: .bottom) {
                                Text(raw)
                                    .font(.callout)
                                    .frame(width: 280, alignment: .leading)
                                    .padding(14)
                            }
                    }
                    rowAction(loc("Fix"), symbol: "wand.and.sparkles") { showFix = true }
                        .help(loc("Correct this dictation and teach Aloud the right words"))
                        .popover(isPresented: $showFix, arrowEdge: .bottom) {
                            FixDictationView(entry: entry, settings: settings)
                        }
                }
                .fixedSize()
                .layoutPriority(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(loc("Copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
            }
            if let raw = entry.rawText {
                Button(loc("Copy Original")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(raw, forType: .string)
                }
            }
            Button(loc("Fix")) { showFix = true }
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short         // "2 min. ago", "3 hr. ago"
        formatter.dateTimeStyle = .named      // "yesterday" beats "1 day ago"
        return formatter
    }()

    /// "less than a minute ago" for the first minute — the system formatter
    /// says "0 seconds ago" there, which reads like a stopwatch.
    static func relativeLabel(for date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return loc("less than a minute ago") }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    // Row actions read as one control: symbol + label, never wrapped, never
    // clipped — the label is the hit target, not just the word.
    private func rowAction(_ title: String,
                           symbol: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }
}

// The "Fix" popover: the user corrects what Aloud typed, the correction is
// diffed against the original, and each changed word or phrase is offered as
// a permanent vocabulary replacement. One popover, two quiet stages.
private struct FixDictationView: View {
    let entry: HistoryEntry
    @ObservedObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var corrected: String
    @State private var candidates: [CorrectionDiff.Candidate] = []
    @State private var accepted: Set<Int> = []
    @State private var reviewing = false
    @State private var noFixFound = false

    init(entry: HistoryEntry, settings: SettingsStore) {
        self.entry = entry
        self.settings = settings
        _corrected = State(initialValue: entry.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if reviewing { review } else { editor }
        }
        .padding(14)
        .frame(width: 360)
    }

    // Stage one: edit the typed text.
    @ViewBuilder private var editor: some View {
        Text(loc("Fix This Dictation"))
            .font(.headline)
        Text(loc("Correct the text below and Aloud learns the words it got wrong."))
            .font(.callout)
            .foregroundStyle(.secondary)
        TextField(loc("Corrected text"), text: $corrected, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(3...8)
            .onChange(of: corrected) { _, _ in noFixFound = false }
        if noFixFound {
            Label(loc("No repeatable fix found"), systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        HStack {
            Spacer()
            Button(loc("Cancel")) { dismiss() }
            Button(loc("Save")) { findCandidates() }
                .keyboardShortcut(.defaultAction)
                .disabled(corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || corrected == entry.text)
        }
    }

    // Stage two: confirm which fixes become standing replacements.
    @ViewBuilder private var review: some View {
        Text(loc("Always Fix These?"))
            .font(.headline)
        Text(loc("Checked fixes are applied to every future dictation. Change them any time in Vocabulary."))
            .font(.callout)
            .foregroundStyle(.secondary)
        ForEach(candidates.indices, id: \.self) { i in
            Toggle(isOn: acceptedBinding(i)) {
                Text(loc("Type “%1$@” instead of “%2$@”", candidates[i].to, candidates[i].from))
            }
            .toggleStyle(.checkbox)
        }
        HStack {
            Spacer()
            Button(loc("Cancel")) { dismiss() }
            Button(loc("Add to Vocabulary")) {
                addAccepted()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(accepted.isEmpty)
        }
    }

    private func acceptedBinding(_ i: Int) -> Binding<Bool> {
        Binding(get: { accepted.contains(i) },
                set: { on in if on { accepted.insert(i) } else { accepted.remove(i) } })
    }

    private func findCandidates() {
        // Candidates already covered by an existing replacement aren't news.
        let found = CorrectionDiff.candidates(original: entry.text, corrected: corrected)
            .filter { candidate in
                !settings.replacements.contains {
                    $0.pattern.caseInsensitiveCompare(candidate.from) == .orderedSame
                }
            }
        guard !found.isEmpty else {
            noFixFound = true
            return
        }
        candidates = found
        accepted = Set(found.indices)
        reviewing = true
    }

    private func addAccepted() {
        for i in accepted.sorted() {
            let c = candidates[i]
            // Skip duplicates in case an identical pattern landed meanwhile.
            guard !settings.replacements.contains(where: {
                $0.pattern.caseInsensitiveCompare(c.from) == .orderedSame
            }) else { continue }
            settings.replacements.append(Replacement(pattern: c.from, replacement: c.to))
        }
    }
}

// MARK: - About

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.accentColor)
                Text("Aloud")
                    .font(.title2.weight(.semibold))
                Text(loc("Version %@", Updater.currentVersion()))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(loc("Dictation that stays on your Mac.\nNo account, no cloud, no telemetry."))
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Link("getaloud.work", destination: URL(string: "https://getaloud.work")!)
                    .font(.callout)
                // Aloud checks on its own; this is for the impatient — which
                // is why it's here and no longer taking a line in the menu.
                Button(loc("Check for Updates")) {
                    NotificationCenter.default.post(name: .aloudCheckForUpdates, object: nil)
                }
                .padding(.top, 4)
            }
            Spacer()
            Divider()
            HStack {
                Spacer()
                Button(loc("Uninstall Aloud"), role: .destructive) {
                    Uninstaller.confirmAndRun()
                }
                .controlSize(.regular)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
