import AppKit
import SwiftUI

// Settings → Agents. Only reachable while the experimental gate is on, so the
// pane's job is the three things the user can still decide: keep it on, how an
// agent's request to listen gets approved, and which of their agent tools know
// Aloud exists.
//
// Deliberately not a wizard. Onboarding walks a new user through detect →
// explain → install → rehearse; this is the place they come back to, so every
// state is on screen at once and nothing has a "next".
//
// NOTE: every user-facing string here goes through `loc(...)`, and the new ones
// still need entries added to Sources/Aloud/Resources/*.lproj/Localizable.strings
// — those tables are shared, so they are not edited from here.
struct AgentsSettings: View {
    @ObservedObject var settings: SettingsStore

    // Injected so a preview — or anyone reasoning about this view — can point
    // it at a scratch directory instead of the real home.
    private let installer: HarnessInstaller

    init(settings: SettingsStore,
         installer: HarnessInstaller = HarnessInstaller(
            home: FileManager.default.homeDirectoryForCurrentUser)) {
        self.settings = settings
        self.installer = installer
    }

    // Read from disk on appear and again after every write, so the rows are
    // reporting the filesystem rather than what we believe we did to it.
    @State private var detected: [DetectedHarness] = []
    // Why a harness could not be set up, kept per row: a failure belongs next
    // to the button that caused it, not in a banner about the whole pane.
    @State private var failures: [AgentHarness: InstallFailure] = [:]
    // Which row's Copy button is showing its confirmation right now.
    @State private var copied: AgentHarness?

    // A refusal we have to show honestly, with whatever the user can paste in
    // our place when there is something to paste.
    private struct InstallFailure {
        let message: String
        let snippet: String?
    }

    var body: some View {
        Form {
            SwiftUI.Section {
                Toggle(loc("Agent voice"), isOn: $settings.experimentalAgentVoice)
            } header: {
                Text(loc("Experimental"))
            } footer: {
                // The one thing a master switch has to promise: off is not
                // uninstall. Otherwise nobody dares turn it off to try it.
                Text(loc("Agents can ask to speak through your speakers and hear your answer. Turning this off refuses every request — anything set up below stays, so switching it back on doesn’t mean starting over."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // Same shape as Clean-up: a segmented choice whose consequence is
            // spelled out underneath, because the modes only make sense next
            // to what they cost.
            SwiftUI.Section {
                Picker(loc("Consent"), selection: $settings.agentConsentMode) {
                    ForEach(AgentConsentMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(settings.agentConsentMode.explanation)
                    Text(loc("The recording indicator always shows while an agent is listening, and nothing leaves this Mac."))
                        .foregroundStyle(.tertiary)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            SwiftUI.Section {
                if detected.isEmpty {
                    Text(loc("No agent tools found on this Mac."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(detected, id: \.harness.id) { entry in
                        harnessRow(entry)
                    }
                }
            } header: {
                Text(loc("Agent Tools"))
            } footer: {
                Text(detected.isEmpty
                     ? loc("Aloud looks for the agent tools you already use. Open one, then come back.")
                     : loc("Aloud writes a short instructions file so an agent knows it can talk to you. Remove deletes that file again."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    // MARK: - Rows

    @ViewBuilder
    private func harnessRow(_ entry: DetectedHarness) -> some View {
        let harness = entry.harness
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                switch entry.scope {
                case .global:
                    if entry.isInstalled {
                        Button(loc("Remove")) { remove(harness) }
                    } else {
                        Button(loc("Install")) { install(harness) }
                    }
                case .perProject:
                    // Never an Install button: there is no global place to put
                    // this, and a button that quietly does nothing is worse
                    // than saying so.
                    copyButton(harness) { install(harness) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(harness.displayName)
                        if entry.isInstalled {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.aloud)
                                .imageScale(.small)
                                .help(loc("Already set up on this Mac"))
                                .accessibilityLabel(loc("Already set up on this Mac"))
                        }
                    }
                    if entry.scope == .perProject {
                        Text(loc("Lives in each project — paste it into %@ in the repos you want it in.",
                                 harness.instructionPath))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let failure = failures[harness] {
                failureNotice(harness, failure)
            }
        }
    }

    // What we could not do, in words, with the thing the user can paste in our
    // place. Never a silent no-op: a settings.json we refuse to rewrite is a
    // decision we made on their behalf, so it gets said out loud.
    @ViewBuilder
    private func failureNotice(_ harness: AgentHarness, _ failure: InstallFailure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let snippet = failure.snippet {
                Text(snippet)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    copyButton(harness) { copy(snippet, from: harness) }
                }
            }
        }
    }

    // The app's copy affordance: the label becomes its own confirmation for a
    // beat, so nothing has to be said about it.
    private func copyButton(_ harness: AgentHarness, action: @escaping () -> Void) -> some View {
        let done = copied == harness
        return Button(action: action) {
            Label(done ? loc("Copied") : loc("Copy"),
                  systemImage: done ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(done ? loc("Copied") : loc("Copy"))
    }

    // MARK: - Actions

    private func refresh() {
        detected = installer.detect()
        // What the bridge reads to decide whether the spoken prompt names the
        // caller. Kept from the same read the rows are drawn from, so the two
        // can never disagree.
        let installed = detected.filter(\.isInstalled).map(\.harness.id)
        if settings.installedHarnesses != installed {
            settings.installedHarnesses = installed
        }
    }

    private func install(_ harness: AgentHarness) {
        failures[harness] = nil
        do {
            switch try installer.install(harness) {
            case .installed:
                refresh()
            case .snippet(let snippet):
                // Not a failed install — a different one. The user is the only
                // one who knows which repo it belongs in.
                copy(snippet.contents, from: harness)
            }
        } catch {
            failures[harness] = describe(error)
        }
    }

    private func remove(_ harness: AgentHarness) {
        failures[harness] = nil
        do {
            try installer.uninstall(harness)
        } catch {
            failures[harness] = describe(error)
        }
        // Whatever happened, redraw from disk: uninstall can pull the skill
        // and still refuse the permissions file.
        refresh()
    }

    // The installer's own errorDescription is English-only, so the sentence the
    // user reads is built here instead, from the case.
    private func describe(_ error: Error) -> InstallFailure {
        switch error as? HarnessInstallError {
        case .unreadableSettings(let path, let snippet):
            return InstallFailure(
                message: loc("%@ isn’t valid JSON, so Aloud left it alone. Add these lines to it by hand.", path),
                snippet: snippet)
        case .writeFailed(let path, let message):
            return InstallFailure(message: loc("Couldn’t write %1$@ — %2$@", path, message),
                                  snippet: nil)
        case nil:
            return InstallFailure(message: error.localizedDescription, snippet: nil)
        }
    }

    private func copy(_ text: String, from harness: AgentHarness) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = harness
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if copied == harness { copied = nil }
        }
    }
}

#Preview {
    AgentsSettings(settings: SettingsStore.shared,
                   installer: HarnessInstaller(home: URL(fileURLWithPath: NSTemporaryDirectory())))
        .frame(width: 560, height: 520)
}
