import SwiftUI

// One calm window, System Settings-style sidebar: General, History, About.
struct SettingsView: View {
    @ObservedObject var controller: DictationController

    enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case dictation = "Dictation"
        case vocabulary = "Vocabulary"
        case history = "History"
        case about = "About"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .dictation: return "waveform"
            case .vocabulary: return "character.book.closed"
            case .history: return "clock"
            case .about: return "info.circle"
            }
        }
    }

    @State private var section: Section = .general

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 160, max: 180)
        } detail: {
            switch section {
            case .general: GeneralSettings(controller: controller)
            case .dictation: DictationSettings(settings: controller.settings)
            case .vocabulary: VocabularySettings(settings: controller.settings)
            case .history: HistorySettings(history: controller.history)
            case .about: AboutSettings()
            }
        }
        .frame(width: 620, height: 420)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var settings: SettingsStore
    @State private var launchAtLogin: Bool
    @State private var devices: [AudioInputDevice] = []

    init(controller: DictationController) {
        self.controller = controller
        self.settings = controller.settings
        _launchAtLogin = State(initialValue: LoginItem.isEnabled)
    }

    var body: some View {
        Form {
            SwiftUI.Section {
                LabeledContent("Dictation key") {
                    HotkeyRecorderView(hotkey: settings.hotkey) { new in
                        controller.updateHotkey(new)
                    }
                }
                Text("Hold to talk, release to type. Press Esc while holding to cancel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } footer: {
                if settings.handsFree {
                    Text("Double-press the key to keep listening hands-free; press Esc to finish.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }

            SwiftUI.Section {
                Picker("Microphone", selection: micSelection) {
                    Text("System default").tag(nil as String?)
                    ForEach(devices) { d in
                        Text(d.name).tag(d.uid as String?)
                    }
                }
            }

            SwiftUI.Section {
                Toggle("Open Aloud at login", isOn: $launchAtLogin)
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
    }

    private var micSelection: Binding<String?> {
        Binding(get: { settings.microphoneUID },
                set: { settings.microphoneUID = $0 })
    }
}

// MARK: - Hotkey recorder

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
            Text(recording ? "Press a key…" : hotkey.displayName)
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
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

struct DictationSettings: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            SwiftUI.Section {
                Picker("Clean-up", selection: $settings.polishLevel) {
                    ForEach(PolishLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                Text(settings.polishLevel.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } footer: {
                Text("The exact words you said are always kept in History, whatever the clean-up level.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }

            SwiftUI.Section {
                Toggle("Hands-free mode", isOn: $settings.handsFree)
                Text(settings.handsFree
                     ? "Double-press the dictation key to keep listening without holding it — edit, click around, keep talking. Press Esc when you're done and everything is typed."
                     : "The dictation key only listens while held.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section {
                Toggle("Sound when recording starts", isOn: $settings.soundCues)
            }

            SwiftUI.Section {
                Toggle("Live typing", isOn: $settings.liveTyping)
                Text(settings.liveTyping
                     ? "Words appear as you say them and settle as Aloud hears more."
                     : "Everything is typed at once when you release the key.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Experimental")
            } footer: {
                Text("Experimental features are still being polished. Turn them off any time to return to the standard experience.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Vocabulary

struct VocabularySettings: View {
    @ObservedObject var settings: SettingsStore
    @State private var newPattern = ""
    @State private var newReplacement = ""

    var body: some View {
        VStack(spacing: 0) {
            if settings.replacements.isEmpty {
                ContentUnavailableView(
                    "No Replacements",
                    systemImage: "character.book.closed",
                    description: Text("Fix words Aloud keeps getting wrong — a name, a product, a term of art. Tell it what it types and what it should be instead, and it's corrected every time."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(settings.replacements) { r in
                        HStack {
                            Text(r.pattern)
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(r.replacement).fontWeight(.medium)
                            Spacer()
                            Button {
                                settings.replacements.removeAll { $0.id == r.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Aloud types…", text: $newPattern)
                    .textFieldStyle(.roundedBorder)
                TextField("It should be…", text: $newReplacement)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let p = newPattern.trimmingCharacters(in: .whitespaces)
                    let r = newReplacement.trimmingCharacters(in: .whitespaces)
                    guard !p.isEmpty, !r.isEmpty else { return }
                    settings.replacements.append(Replacement(pattern: p, replacement: r))
                    newPattern = ""; newReplacement = ""
                }
                .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty
                          || newReplacement.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
    }
}

// MARK: - History

struct HistorySettings: View {
    @ObservedObject var history: HistoryStore

    var body: some View {
        VStack(spacing: 0) {
            if history.entries.isEmpty {
                ContentUnavailableView("No Dictations Yet",
                                       systemImage: "quote.bubble",
                                       description: Text("Recent dictations appear here. They stay on this Mac."))
            } else {
                List(history.entries) { entry in
                    HistoryRow(entry: entry)
                }
                .scrollContentBackground(.hidden)
                Divider()
                HStack {
                    Spacer()
                    Button("Clear History") { history.clear() }
                }
                .padding(12)
            }
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    @State private var showRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.text)
                .lineLimit(3)
            HStack(spacing: 8) {
                Text(entry.date, style: .relative)
                if entry.rawText != nil {
                    Button(showRaw ? "Hide original" : "Show original") {
                        withAnimation(.spring(duration: 0.25)) { showRaw.toggle() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if showRaw, let raw = entry.rawText {
                Text(raw)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
            }
            if let raw = entry.rawText {
                Button("Copy Original") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(raw, forType: .string)
                }
            }
        }
    }
}

// MARK: - About

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Aloud")
                .font(.title2.weight(.semibold))
            Text("Version \(Updater.currentVersion())")
                .foregroundStyle(.secondary)
            Text("Dictation that stays on your Mac.\nNo account, no cloud, no telemetry.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
            Link("Website & source", destination: URL(string: "https://github.com/\(AppPaths.githubRepo)")!)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
