import AppKit
import SwiftUI

// Settings → Agent Speak. Only reachable while the experimental gate is on —
// and the gate itself lives in General → Experimental with the other
// experiments, not here: a pane that can switch itself out of existence is a
// trapdoor, and the user came here to set the feature up rather than to
// reconsider it.
//
// So the pane answers the two questions that are actually left: is an agent
// asked before it listens, and which agent tools know Aloud exists.
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
    // The same beat for the phrase, which belongs to no row.
    @State private var copiedPhrase = false

    // A refusal we have to show honestly, with whatever the user can paste in
    // our place when there is something to paste.
    private struct InstallFailure {
        let message: String
        let snippet: String?
    }

    @State private var bridgeFailure: String?

    var body: some View {
        Form {
            // The bridge is on but did not come up. Without this the failure is
            // invisible from both ends — a .app's stderr goes nowhere a user
            // looks, and agents are simply told the feature is off.
            if settings.experimentalAgentVoice, let failure = bridgeFailure {
                SwiftUI.Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loc("Agents can’t reach Aloud right now."))
                            Text(failure)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text(loc("Restarting Aloud usually clears this."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // One question, then the question it opens up. A three-way picker
            // made the user rank modes they had no vocabulary for; a switch
            // asks the thing they actually have an opinion about — do I get
            // asked — and only then how the asking happens.
            SwiftUI.Section {
                Toggle(loc("Ask before listening"), isOn: asksFirst)
                if settings.agentAsksFirst {
                    Toggle(loc("Ask out loud"), isOn: $settings.agentAsksOutLoud)
                }
            } header: {
                Text(loc("Permission"))
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(permissionExplanation)
                    Text(loc("The recording indicator always shows while an agent is listening, and nothing leaves this Mac."))
                        .foregroundStyle(.tertiary)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            // Who the user hears. Directly under Permission because the two
            // answer the same question from opposite ends — that one decides
            // whether an agent may speak to you, this one decides what it
            // sounds like when it does — and both are about the conversation
            // rather than about which tools are wired up.
            VoiceChooser(settings: settings)

            // Setting a tool up teaches its agent that Aloud exists; whether
            // the agent then *reaches* for it on any given turn is a judgement
            // it makes. This is the way that does not depend on that judgement,
            // and it belongs here rather than in the documentation because the
            // moment the user wants it is the moment they notice an agent went
            // quiet. Shown only once something is actually set up — offered
            // before that, it is a phrase that would do nothing.
            //
            // Above the tool list rather than below it: the list is long, and
            // this is the one thing on the pane a user comes back to *use*
            // rather than to configure once.
            if detected.contains(where: \.isInstalled) {
                SwiftUI.Section {
                    HStack(alignment: .top, spacing: 12) {
                        Text(AgentVoiceInstructions.spokenReplyRequest)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        copyButton(done: copiedPhrase) {
                            copyPhrase()
                        }
                        .help(loc("Copy this to paste into an agent"))
                    }
                } header: {
                    Text(loc("Tell Your Agent"))
                } footer: {
                    Text(loc("Agents you set up can ask you out loud on their own. Saying this once at the start of a session makes it certain."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                     : loc("Setting one up adds a short instructions file, a line in the tool’s own instructions, and permission to run Aloud. Remove takes them back out and stops Aloud setting that tool up again. Turning Agent Speak off leaves them in place."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        // The second switch arrives and leaves with the first one's answer, so
        // the card grows rather than snapping to a new height.
        .animation(.default, value: settings.agentAsksFirst)
        .onAppear(perform: refresh)
    }

    // The switch reads and writes the stored mode through the store, so the
    // pane never holds a second copy of the answer.
    private var asksFirst: Binding<Bool> {
        Binding(get: { settings.agentAsksFirst },
                set: { settings.agentAsksFirst = $0 })
    }

    // What the current pair of switches costs, in one sentence. Written from
    // the user's side of the microphone — what happens to them, not which mode
    // is selected.
    private var permissionExplanation: String {
        guard settings.agentAsksFirst else {
            return loc("Agents start listening as soon as they ask, without checking with you first.")
        }
        return settings.agentAsksOutLoud
            ? loc("Aloud asks through your speakers and waits for you to say yes — no need to look at the screen. You’re asked once per session.")
            : loc("The question appears on the recording indicator and waits for you to accept. You’re asked once per session.")
    }

    // MARK: - Rows

    // One line per tool: the name, whether it is set up, and the one button
    // that changes that. Everything else a row could say — where the file
    // lands, what a per-project tool means — is a tooltip, because a list of
    // eight tools is read by scanning it, not by reading it.
    @ViewBuilder
    private func harnessRow(_ entry: DetectedHarness) -> some View {
        let harness = entry.harness
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                switch entry.scope {
                case .global:
                    if entry.isInstalled {
                        Button(loc("Remove")) { remove(harness) }
                            .buttonStyle(.text)
                    } else {
                        Button(loc("Set Up")) { install(harness) }
                            .buttonStyle(.text)
                    }
                case .perProject:
                    // Never a Set Up button: there is no global place to put
                    // this, and a button that quietly does nothing is worse
                    // than saying so. The tooltip carries the why.
                    copyButton(harness) { install(harness) }
                        .help(loc("Paste it into %@ in each project you want it in.",
                                  harness.instructionPath))
                }
            } label: {
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
            }

            if let failure = failures[harness] {
                failureNotice(harness, failure)
            }
        }
    }

    // What we could not do, in one sentence, with the thing the user can paste
    // in our place behind the Copy button rather than dumped into the row.
    // Never a silent no-op: a settings.json we refuse to rewrite is a decision
    // we made on their behalf, so it gets said out loud.
    @ViewBuilder
    private func failureNotice(_ harness: AgentHarness, _ failure: InstallFailure) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let snippet = failure.snippet {
                Spacer(minLength: 4)
                copyButton(harness) { copy(snippet, from: harness) }
                    // Sits against footnote-sized text, so it matches it —
                    // controlSize only ever spoke to the bezel that's gone.
                    .font(.footnote)
                    .help(loc("Copy the lines to add"))
            }
        }
    }

    // The app's copy affordance: the label becomes its own confirmation for a
    // beat, so nothing has to be said about it.
    private func copyButton(_ harness: AgentHarness, action: @escaping () -> Void) -> some View {
        copyButton(done: copied == harness, action: action)
    }

    // Same button, for the one thing on this pane that is copied without
    // belonging to a row.
    private func copyButton(done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(done ? loc("Copied") : loc("Copy"),
                  systemImage: done ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        // Confirmed in the app's own blue: the swap is Aloud reporting back,
        // not another thing to click.
        .buttonStyle(.text(done ? .aloud : .accentColor))
        .accessibilityLabel(done ? loc("Copied") : loc("Copy"))
    }

    // MARK: - Actions

    // Off the main thread, then back to it.
    //
    // `detect()` reads every harness's instruction file, and this runs from
    // `onAppear` — so the pane opened by blocking the main thread on eight
    // file reads, and then published `installedHarnesses` from inside the
    // appear pass, which is a store mutated during a view update. Both go away
    // by doing the reading somewhere else and assigning when it is done.
    private func refresh() {
        let installer = installer
        Task {
            let found = await Task.detached { installer.detect() }.value
            let failure = await Task.detached { BridgeStartFailure.read(stateDir: AppPaths.stateDir) }.value
            detected = found
            bridgeFailure = failure
            // What the bridge reads to decide whether the spoken prompt names
            // the caller. Kept from the same read the rows are drawn from, so
            // the two can never disagree.
            let installed = found.filter(\.isInstalled).map(\.harness.id)
            if settings.installedHarnesses != installed {
                settings.installedHarnesses = installed
            }
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
            failures[harness] = describe(error, removing: false)
        }
    }

    private func remove(_ harness: AgentHarness) {
        failures[harness] = nil
        do {
            try installer.uninstall(harness)
        } catch {
            failures[harness] = describe(error, removing: true)
        }
        // Whatever happened, redraw from disk: uninstall can pull the skill
        // and still refuse the permissions file.
        refresh()
    }

    // The installer's own errorDescription is English-only, so the sentence the
    // user reads is built here instead, from the case.
    private func describe(_ error: Error, removing: Bool) -> InstallFailure {
        switch error as? HarnessInstallError {
        case .unreadableSettings(let path, let snippet):
            // The snippet is the entries to add, so it only helps an install.
            // On removal the user needs to take those lines out, not put them
            // in — offering the add-snippet would be exactly backwards.
            if removing {
                return InstallFailure(
                    message: loc("%@ isn’t valid JSON, so Aloud left it alone. Remove the Aloud permission entries by hand.", path),
                    snippet: nil)
            }
            return InstallFailure(
                message: loc("%@ isn’t valid JSON, so Aloud left it alone. Add these lines to it by hand.", path),
                snippet: snippet)
        case .damagedBlock(let path):
            return InstallFailure(
                message: loc("%@ has an Aloud section with a broken marker, so Aloud left it alone. Fix or remove that section by hand.", path),
                snippet: nil)
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

    private func copyPhrase() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentVoiceInstructions.spokenReplyRequest, forType: .string)
        copiedPhrase = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            copiedPhrase = false
        }
    }
}

#Preview {
    AgentsSettings(settings: SettingsStore.shared,
                   installer: HarnessInstaller(home: URL(fileURLWithPath: NSTemporaryDirectory())))
        .frame(width: 560, height: 520)
}
