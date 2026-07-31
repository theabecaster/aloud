import Foundation

// Teaching agent harnesses that Aloud's voice CLI exists.
//
// The bridge is useless if the agent never calls it, so install writes an
// instruction file into each harness's own config — a skill for Claude Code, a
// section in an instructions file for the rest. Two of the four are global and
// we write them; the other two are per-project by design (see
// docs/agent-voice-bridge.md §6) and we hand back a snippet rather than reach
// into somebody's repo.
//
// Everything here is filesystem work on files we do not own, so the rules are
// strict: never write a file we could not parse, back up anything we modify,
// wrap every append in markers so removal is exact, and make a second install a
// no-op down to the byte. The home directory is injected so tests never touch
// the developer's real `~`.

// MARK: - the harnesses

enum AgentHarness: String, CaseIterable, Codable {
    case claudeCode = "claude-code"
    case codex
    case cursor
    case copilot

    // The id baked into `--harness` in the instructions we write, and the label
    // the indicator shows. Never authentication — see §7.1c.
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .copilot: return "GitHub Copilot"
        }
    }

    enum Scope {
        case global      // one install covers every project on this Mac
        case perProject  // the config lives in the repo, so we can only offer a snippet
    }

    var scope: Scope {
        switch self {
        // Cursor keeps global skills in exactly the layout Claude Code uses —
        // ~/.cursor/skills/<name>/SKILL.md — verified against a real installed
        // skill on this machine. An earlier draft had it as per-project on the
        // strength of .cursor/rules/*.mdc, which is a different mechanism.
        case .claudeCode, .codex, .cursor: return .global
        case .copilot: return .perProject
        }
    }

    // Home-relative paths that mean "this harness has been run on this Mac".
    // Any one of them is enough — the harnesses disagree about where they keep
    // state and change their minds between versions.
    var detectionPaths: [String] {
        switch self {
        case .claudeCode:
            return [".claude"]
        case .codex:
            return [".codex"]
        case .cursor:
            return [".cursor", "Library/Application Support/Cursor"]
        case .copilot:
            // The CLI/editor plugins keep version state here; the VS Code app
            // dir catches the extension without a separate copilot marker.
            return [".config/github-copilot", ".copilot", "Library/Application Support/Code"]
        }
    }

    // Where the instructions end up. Home-relative for the global pair,
    // repo-relative for the per-project pair.
    var instructionPath: String {
        switch self {
        case .claudeCode: return ".claude/skills/aloud-voice/SKILL.md"
        case .codex: return ".codex/AGENTS.md"
        case .cursor: return ".cursor/skills/aloud-voice/SKILL.md"
        case .copilot: return ".github/copilot-instructions.md"
        }
    }
}

struct DetectedHarness: Equatable {
    let harness: AgentHarness
    let scope: AgentHarness.Scope
    // Whether our instructions are already in place. Always false for the
    // per-project pair — we never wrote them, so we cannot claim they are there.
    let isInstalled: Bool
}

// MARK: - results

// A per-project harness is not a failed install, it is a different one: the
// user pastes the text into the repo they want it in. Modelling it as a result
// rather than an error keeps the Settings pane from treating it as a problem.
enum InstallResult: Equatable {
    case installed(changed: [URL])
    case snippet(ProjectSnippet)
}

struct ProjectSnippet: Equatable {
    let harness: AgentHarness
    let relativePath: String   // where the user should put it, inside their project
    let contents: String
}

enum HarnessInstallError: LocalizedError, Equatable {
    // The one failure that must never become a write. Someone's settings.json
    // is the only thing standing between them and a Claude Code that won't
    // start; clobbering it to add a permission line is not a trade we make.
    case unreadableSettings(path: String, snippet: String)
    case writeFailed(path: String, message: String)

    var errorDescription: String? {
        switch self {
        case .unreadableSettings(let path, _):
            return "\(path) isn't valid JSON, so Aloud left it alone. Add the permission entries by hand."
        case .writeFailed(let path, let message):
            return "Couldn't write \(path): \(message)"
        }
    }
}

// MARK: - what we tell the agent

// One source of truth for the behaviour we are installing. Every harness gets
// the same words; only the wrapper (frontmatter, heading level) differs. Five
// harness-specific copies of this text would drift within a release.
enum AgentVoiceInstructions {
    static let markerStart = "<!-- aloud-voice:start -->"
    static let markerEnd = "<!-- aloud-voice:end -->"

    static let summary = "Speak to the user and hear their answer through Aloud, so you can ask a question mid-task instead of ending your turn."

    // The verbs a distributed build exposes (CLI.swift). Also the verbs Claude
    // Code's allowlist has to cover, which is why they live next to the text
    // that teaches them rather than in the installer.
    static let verbs = ["claim", "listen", "speak", "release"]

    // MARK: how the agent types our name
    //
    // One function, and everything that has to agree comes out of it: the
    // sample commands in the instructions and the `Bash(… :*)` patterns in
    // Claude Code's allowlist. They only match if they are character-identical,
    // and an allowlist that misses means a permission prompt on the first
    // `listen` — hands-free broken on turn one, the failure §6 warns about. A
    // comment asking two call sites to stay in step is not enough; this is the
    // step.
    static func invocation(command: String) -> String { shellQuoted(command) }

    // `Bash(<invocation> <verb>:*)` — Claude Code matches the literal prefix of
    // the command line, so the quoting has to be the quoting the agent will
    // actually type.
    static func permissionEntries(command: String) -> [String] {
        let invocation = invocation(command: command)
        return verbs.map { "Bash(\(invocation) \($0):*)" }
    }

    // Recognising our entries on the way out is deliberately looser than
    // writing them. The allowlist in front of us may have been written by an
    // older Aloud that assumed a bare `aloud` on PATH, or by this one before
    // the user moved the bundle — and an entry we fail to recognise is one we
    // leave behind pointing at a binary that no longer exists. Anything shaped
    // like `Bash(<something named aloud> <one of our verbs>:*)` is ours.
    static func isPermissionEntry(_ entry: String) -> Bool {
        guard entry.hasPrefix("Bash("), entry.hasSuffix(":*)") else { return false }
        let inner = entry.dropFirst("Bash(".count).dropLast(":*)".count)
        guard let space = inner.lastIndex(of: " ") else { return false }
        guard verbs.contains(String(inner[inner.index(after: space)...])) else { return false }
        let command = String(inner[..<space])
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return (command as NSString).lastPathComponent.lowercased() == "aloud"
    }

    // The CLI lives inside an app bundle, so its path can contain a space the
    // moment somebody keeps their apps somewhere else. Unquoted, the agent's
    // shell would split it; quoted differently in the two places, the allowlist
    // would stop matching. Both come from here.
    private static func shellQuoted(_ command: String) -> String {
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./")
        if !command.isEmpty, command.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return command
        }
        return "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // `command` is the binary the harness should invoke; `harness` is baked in
    // so the agent never has to know its own name (§7.1c).
    static func body(harness: AgentHarness, command: String) -> String {
        let id = harness.id
        let command = invocation(command: command)
        return #"""
        # Talking to the user out loud

        Aloud gives you a voice channel to the person you are working for. You can
        say something through their speakers and hear their spoken answer, which
        means you can ask a question in the middle of a task instead of stopping
        and waiting for them to come back to the keyboard.

        Reach for it when you need a short decision from the user and they are
        unlikely to be watching the screen. Do not narrate your work with it.

        ## How to behave

        **Speak before every listen.** The whole point of this feature is that the
        user is not looking at the screen. Opening the microphone without saying
        anything asks a question nobody knows was asked. Always `speak` first, then
        `listen`.

        **Say the context, briefly.** Not "what do you think?" — say "the migration
        test is failing, should I roll it back or fix it forward?" Give them enough
        to answer without switching windows, in one or two sentences. It is a
        prompt, not a status report.

        **Honour "stop telling me every time."** If the user asks you to skip the
        preamble, stop speaking context before each listen for the rest of the
        session and just listen. Do not go back to it later in the same session.

        **Voice can be unavailable, and that is not an error.** The user can switch
        this off at any moment, or decline a single request. A refusal is a normal
        answer, not a bug: fall back to asking in text and carry on. Never retry in
        a loop.

        | refusal | what it means | what to do |
        |---|---|---|
        | `disabled` | voice is switched off in Aloud | stop asking for the rest of the session; use text |
        | `denied` | the user declined this request | use text now; asking again later is fine |
        | `timeout` | nobody answered | use text; do not immediately ask again |
        | `queued` | another agent holds the microphone | ask in text instead of waiting |
        | `unavailable` | Aloud isn't running | use text |

        ## Mechanics

        Claim a lease before using the microphone or the speakers, hold it for the
        whole conversation, and release it when you are done. Consent is granted
        once per lease, so a follow-up question inside the same lease costs the user
        nothing.

        ```sh
        \#(command) claim   --harness \#(id)                  # {"lease":"L1","status":"granted"}
        \#(command) speak   --harness \#(id) --lease L1 "The migration test is failing. Roll it back, or fix it forward?"
        \#(command) listen  --harness \#(id) --lease L1        # blocks, returns {"text":"..."}
        \#(command) release --harness \#(id) --lease L1        # always, even after an error
        ```

        - Pass `--harness \#(id)` on every call.
        - `claim` returns immediately. If it comes back `{"status":"queued"}`, ask
          your question in text instead — do not spin on it, and do not sleep and
          retry.
        - `listen` blocks and ends on silence, returning the final transcript. That
          is the mode you want almost always. `--start` / `--poll` / `--stop` exists
          for when you need to cut in as soon as you have heard enough, and every
          poll costs a full turn, so use it deliberately.
        - `release` when the conversation is over. A lease nobody releases keeps the
          microphone away from everyone else until it times out.
        - The returned text is the best cleanup this Mac can do. `"cleanup":"basic"`
          means it is closer to a raw transcript than a summary.
        """#
    }

    // The whole file, for harnesses where we own the file.
    static func skillFile(harness: AgentHarness, command: String) -> String {
        let frontmatter = """
        ---
        name: aloud-voice
        description: \(summary)
        ---
        """
        return frontmatter + "\n\n" + markedBlock(body(harness: harness, command: command))
    }

    // A section to append to a file somebody else owns. The markers are what
    // make removal exact and a second install a no-op.
    static func markedBlock(_ inner: String) -> String {
        "\(markerStart)\n\(inner)\n\(markerEnd)\n"
    }
}

// MARK: - the installer

struct HarnessInstaller {
    // Injected so tests run against a scratch directory. Nothing in this type
    // may reach for FileManager.default.homeDirectoryForCurrentUser.
    let home: URL
    // How the instructions tell the agent to invoke us — and, through
    // `AgentVoiceInstructions.permissionEntries`, what Claude Code's allowlist
    // is generated from. A dev build pointing at a checkout binary should not
    // tell agents to run the installed one.
    let command: String
    private let fm: FileManager

    // The real home. The app passes this; tests must not.
    static var userHome: URL { FileManager.default.homeDirectoryForCurrentUser }

    // There is no `aloud` on PATH — the CLI ships inside the app bundle — so
    // the running executable's own path is the only invocation that works
    // without asking the user to edit their shell profile or dropping a shim
    // into a directory we would then have to remember to remove. It also means
    // a dev build teaches agents about the dev build.
    static var defaultCommand: String {
        let fallback = "/Applications/Aloud.app/Contents/MacOS/Aloud"
        guard let path = Bundle.main.executableURL?.path else { return fallback }
        // Gatekeeper may run a freshly downloaded app from a randomised
        // read-only mount. Baking that path into somebody's settings.json would
        // outlive the mount by months.
        if path.contains("/AppTranslocation/") { return fallback }
        return path
    }

    // The four verbs the prod CLI exposes, allowed for the exact command the
    // instructions tell the agent to run — so the first `listen` doesn't stop
    // for a permission prompt. In a feature whose entire point is not touching
    // the keyboard, that prompt is the difference between a demo that lands and
    // one that stalls on turn one.
    var claudePermissionEntries: [String] {
        AgentVoiceInstructions.permissionEntries(command: command)
    }

    init(home: URL, command: String = HarnessInstaller.defaultCommand, fileManager: FileManager = .default) {
        self.home = home
        self.command = command
        self.fm = fileManager
    }

    // MARK: detection

    func detect() -> [DetectedHarness] {
        AgentHarness.allCases.compactMap { harness in
            guard harness.detectionPaths.contains(where: { exists(home.appendingPathComponent($0)) })
            else { return nil }
            return DetectedHarness(harness: harness,
                                   scope: harness.scope,
                                   isInstalled: isInstalled(harness))
        }
    }

    // MARK: state

    // Answered from the instruction file alone, not from settings.json: the
    // file is the thing we own, and a user who hand-edits their permissions has
    // not uninstalled anything.
    func isInstalled(_ harness: AgentHarness) -> Bool {
        switch harness.scope {
        case .perProject:
            // We never wrote into their repo, so we cannot know and must not guess.
            return false
        case .global:
            let url = home.appendingPathComponent(harness.instructionPath)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.contains(AgentVoiceInstructions.markerStart)
        }
    }

    // MARK: install

    func install(_ harness: AgentHarness) throws -> InstallResult {
        switch harness {
        case .cursor:
            let skill = home.appendingPathComponent(harness.instructionPath)
            let file = AgentVoiceInstructions.skillFile(harness: .cursor, command: command)
            let wrote = try writeIfDifferent(file, to: skill)
            return .installed(changed: wrote ? [skill] : [])

        case .copilot:
            let block = AgentVoiceInstructions.markedBlock(
                AgentVoiceInstructions.body(harness: .copilot, command: command))
            return .snippet(ProjectSnippet(harness: .copilot,
                                           relativePath: harness.instructionPath,
                                           contents: block))
        case .codex:
            let url = home.appendingPathComponent(harness.instructionPath)
            let block = AgentVoiceInstructions.markedBlock(
                AgentVoiceInstructions.body(harness: .codex, command: command))
            let changed = try upsertBlock(block, in: url)
            return .installed(changed: changed ? [url] : [])

        case .claudeCode:
            // Order matters. The permission file is the one that can refuse, so
            // parse it before writing anything — a failure here must leave a
            // half-installed skill behind.
            let settings = claudeSettingsURL
            let updated = try claudeSettings(at: settings, addingEntries: true)

            var changed: [URL] = []
            let skill = home.appendingPathComponent(harness.instructionPath)
            let file = AgentVoiceInstructions.skillFile(harness: .claudeCode, command: command)
            if try writeIfDifferent(file, to: skill) { changed.append(skill) }
            if let data = updated {
                try write(data, to: settings)
                changed.append(settings)
            }
            return .installed(changed: changed)
        }
    }

    // Delete a skill file we wrote, and the directory it sat in if that leaves
    // it empty. Guarded by our marker: a hand-written skill that happens to
    // share the name is not something we get to remove.
    private func removeSkillDirectory(at skill: URL) throws {
        guard let text = try? String(contentsOf: skill, encoding: .utf8),
              text.contains(AgentVoiceInstructions.markerStart) else { return }
        try? fm.removeItem(at: skill)
        removeBackup(of: skill)
        let dir = skill.deletingLastPathComponent()
        if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
            try? fm.removeItem(at: dir)
        }
    }

    // MARK: uninstall

    // Removing our instructions is the point, but leaving `.aloud-backup` files
    // scattered through somebody's ~/.claude is our litter too — and worse, the
    // backup we take on the way out would be a copy of the file *with* our
    // entries in it. So a clean uninstall takes them with it. The one case
    // where a backup is worth keeping is the one where uninstall threw: then it
    // is the user's only record of what the file looked like before we touched
    // it, and we never reach the deletion.
    func uninstall(_ harness: AgentHarness) throws {
        switch harness {
        case .copilot:
            return  // nothing of ours is on disk to remove

        case .cursor:
            try removeSkillDirectory(at: home.appendingPathComponent(harness.instructionPath))

        case .codex:
            try removeBlock(from: home.appendingPathComponent(harness.instructionPath))

        case .claudeCode:
            let skill = home.appendingPathComponent(harness.instructionPath)
            try removeSkillDirectory(at: skill)
            // A malformed settings.json on the way out is still not ours to
            // rewrite — surface it so the pane can say the allowlist is stale.
            if let data = try claudeSettings(at: claudeSettingsURL, addingEntries: false) {
                try write(data, to: claudeSettingsURL)
            }
            removeBackup(of: claudeSettingsURL)
        }
    }

    // MARK: - Claude Code settings.json

    var claudeSettingsURL: URL { home.appendingPathComponent(".claude/settings.json") }

    // Returns the bytes to write, or nil when nothing needs changing — which is
    // what makes a second install byte-identical rather than merely equivalent.
    // Throws rather than writing if the file is not JSON we understand.
    private func claudeSettings(at url: URL, addingEntries adding: Bool) throws -> Data? {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data),
                  let object = parsed as? [String: Any] else {
                throw HarnessInstallError.unreadableSettings(path: url.path,
                                                             snippet: permissionSnippet)
            }
            root = object
        } else if !adding {
            return nil  // no file, nothing to take out
        }

        var permissions: [String: Any] = [:]
        if let existing = root["permissions"] {
            guard let object = existing as? [String: Any] else {
                throw HarnessInstallError.unreadableSettings(path: url.path,
                                                             snippet: permissionSnippet)
            }
            permissions = object
        }

        // Kept as `[Any]` so a rule shape we don't recognise survives the round
        // trip untouched — we are here to add four strings, not to normalise
        // somebody's allowlist.
        var allow: [Any] = []
        if let existing = permissions["allow"] {
            guard let list = existing as? [Any] else {
                throw HarnessInstallError.unreadableSettings(path: url.path,
                                                             snippet: permissionSnippet)
            }
            allow = list
        }

        var changed = false
        if adding {
            let present = Set(allow.compactMap { $0 as? String })
            for entry in claudePermissionEntries where !present.contains(entry) {
                allow.append(entry)
                changed = true
            }
        } else {
            let before = allow.count
            allow.removeAll { element in
                guard let entry = element as? String else { return false }
                return AgentVoiceInstructions.isPermissionEntry(entry)
            }
            changed = allow.count != before
        }
        guard changed else { return nil }

        permissions["allow"] = allow
        root["permissions"] = permissions
        return try JSONSerialization.data(withJSONObject: root,
                                          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // What we offer when we refuse to touch a broken settings.json.
    var permissionSnippet: String {
        let entries = claudePermissionEntries.map { "    \"\($0)\"" }.joined(separator: ",\n")
        return "\"permissions\": {\n  \"allow\": [\n\(entries)\n  ]\n}"
    }

    // MARK: - markdown blocks

    // Insert our block, or replace the one already there. Returns whether the
    // file changed, so a repeat install reports honestly instead of claiming a
    // write it never made.
    private func upsertBlock(_ block: String, in url: URL) throws -> Bool {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated: String
        if existing.contains(AgentVoiceInstructions.markerStart) {
            updated = replacingBlock(in: existing, with: block)
        } else if existing.isEmpty {
            updated = block
        } else {
            let separator = existing.hasSuffix("\n") ? "\n" : "\n\n"
            updated = existing + separator + block
        }
        return try writeIfDifferent(updated, to: url)
    }

    private func replacingBlock(in text: String, with block: String) -> String {
        let stripped = removingBlock(from: text)
        if stripped.isEmpty { return block }
        let separator = stripped.hasSuffix("\n") ? "\n" : "\n\n"
        return stripped + separator + block
    }

    private func removeBlock(from url: URL) throws {
        guard let existing = try? String(contentsOf: url, encoding: .utf8),
              existing.contains(AgentVoiceInstructions.markerStart) else { return }
        let stripped = removingBlock(from: existing)
        if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The file held nothing but our section, so we created it. Leaving
            // an empty AGENTS.md behind is litter, not caution.
            try? fm.removeItem(at: url)
            removeBackup(of: url)
            return
        }
        _ = try writeIfDifferent(stripped, to: url)
        removeBackup(of: url)
    }

    // Line-based rather than range-based so a stray marker inside a code fence
    // cannot swallow half the file, and so the blank line we inserted with the
    // block comes back out with it.
    private func removingBlock(from text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == AgentVoiceInstructions.markerStart })
        else { return text }
        guard let end = lines[start...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == AgentVoiceInstructions.markerEnd })
        else { return text }

        lines.removeSubrange(start...end)
        // Collapse the separator blank line we added on the way in.
        if start > 0, start < lines.count, lines[start - 1].isEmpty, lines[start].isEmpty {
            lines.remove(at: start)
        } else if start > 0, start == lines.count, lines[start - 1].isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - file plumbing

    private func exists(_ url: URL) -> Bool {
        fm.fileExists(atPath: url.path)
    }

    @discardableResult
    private func writeIfDifferent(_ text: String, to url: URL) throws -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        if let current = try? Data(contentsOf: url), current == data { return false }
        try write(data, to: url)
        return true
    }

    private func write(_ data: Data, to url: URL) throws {
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            backUp(url)
            try data.write(to: url, options: .atomic)
        } catch {
            throw HarnessInstallError.writeFailed(path: url.path, message: error.localizedDescription)
        }
    }

    // One backup per file, overwritten. A timestamped pile in somebody's
    // ~/.claude is worse than the single copy that answers "what did it look
    // like before Aloud touched it".
    private func backUp(_ url: URL) {
        guard exists(url) else { return }
        let backup = url.appendingPathExtension("aloud-backup")
        try? fm.removeItem(at: backup)
        try? fm.copyItem(at: url, to: backup)
    }

    // Only ever called once the file it belonged to has been put back the way
    // we found it. Best-effort: a backup we cannot delete is untidy, never a
    // reason to fail an uninstall.
    private func removeBackup(of url: URL) {
        try? fm.removeItem(at: url.appendingPathExtension("aloud-backup"))
    }
}
