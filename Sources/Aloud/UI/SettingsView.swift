import SwiftUI

// One calm window, System Settings-style sidebar: General, History, About.
struct SettingsView: View {
    @ObservedObject var controller: DictationController

    enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case history = "History"
        case about = "About"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
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

// Click, then press the desired key (a lone modifier like right ⌘ counts).
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
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.text)
                            .lineLimit(3)
                        Text(entry.date, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.text, forType: .string)
                        }
                    }
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
