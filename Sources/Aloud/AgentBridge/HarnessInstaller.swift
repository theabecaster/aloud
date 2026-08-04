import Foundation

// Teaching agent harnesses that Aloud's voice CLI exists.
//
// The bridge is useless if the agent never calls it, so install writes an
// instruction file into each harness's own config — a skill file for the ones
// that have a skills directory, an appended section for the ones that have a
// single instructions file. Most are global and we write them; the per-project
// ones (see docs/agent-voice-bridge.md §6) get a snippet rather than us
// reaching into somebody's repo.
//
// Most paths in the table below were verified by listing a real installation on
// a real Mac, never from documentation. That is not politeness: the launch set
// already shipped one wrong assumption (Cursor filed as per-project because of
// `.cursor/rules/*.mdc`, when `~/.cursor/skills/<name>/SKILL.md` exists and
// behaves exactly like Claude Code's), and a harness added from memory looks
// installed while doing nothing at all.
//
// Two rows — OpenClaw and Hermes — are the deliberate exception: neither is
// installed on this Mac, so both were built from published documentation and
// source. Each carries a comment saying so at every point where it could be
// wrong, and each is detected off a marker file only the real tool creates, so
// the failure mode is "row never appears" rather than "row says Installed while
// writing somewhere nobody reads".
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
    // Added after launch. New cases go on the end: `allCases` order is the
    // order the Settings pane draws its rows in, and the detection tests read
    // it positionally.
    case opencode
    case pi
    // Documentation-derived rather than verified against a live install — see
    // the comments on `mechanism`, `detectionPaths` and `instructionPath`.
    case openclaw
    case hermes

    // The id baked into `--harness` in the instructions we write, and the label
    // the indicator shows. Never authentication — see §7.1c.
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .copilot: return "GitHub Copilot"
        case .opencode: return "OpenCode"
        // Lowercase on purpose: the binary, the config directory and the
        // project's own docs all call it `pi`.
        case .pi: return "pi"
        case .openclaw: return "OpenClaw"
        case .hermes: return "Hermes"
        }
    }

    // How the instructions get in front of the agent. Three shapes have covered
    // every harness examined so far, which is the point — adding one should be
    // a row in this table and a test, and if it ever needs a fourth shape the
    // abstraction is wrong and that is worth knowing early.
    enum Mechanism {
        case skillFile      // a skills directory we own outright: <root>/skills/<name>/SKILL.md
        case appendedBlock  // somebody else's instructions file; we append a marked section
        case snippet        // the file belongs in the user's repo, so we hand back text
    }

    var mechanism: Mechanism {
        switch self {
        // Cursor keeps global skills in exactly the layout Claude Code uses —
        // ~/.cursor/skills/<name>/SKILL.md — verified against a real installed
        // skill on this machine. An earlier draft had it as per-project on the
        // strength of .cursor/rules/*.mdc, which is a different mechanism.
        //
        // OpenCode and pi were verified the same way, and both times by reading
        // the code that does the scanning rather than trusting the directory
        // that happened to be on disk:
        //  - OpenCode's config directories are ~/.config/opencode and ~/.opencode,
        //    and each is scanned for `{skill,skills}/**/SKILL.md`. We write the
        //    second, because it is plain home-relative while the first moves
        //    with XDG_CONFIG_HOME and this installer only knows about `home`.
        //  - pi auto-discovers `<agentDir>/skills/**/SKILL.md`, and its agentDir
        //    is ~/.pi/agent. Note ~/.pi/skills — which does exist on this Mac,
        //    put there by another tool — is *not* read: that is pi's per-project
        //    layout applied to the home directory by mistake. Exactly the kind
        //    of plausible wrong path that looks installed and does nothing.
        //
        // OpenClaw and Hermes are the two rows that were *not* verified against
        // an installed copy — neither is on this Mac. They are here on the
        // strength of published docs plus the projects' own source, which is
        // weaker evidence than a directory listing and is called out again at
        // every path below:
        //  - OpenClaw's skill roots are, highest precedence first, <workspace>/skills,
        //    <workspace>/.agents/skills, ~/.agents/skills, then <state-dir>/skills
        //    with the state dir defaulting to ~/.openclaw. A SKILL.md anywhere
        //    under a root counts, and the skill's name comes from frontmatter.
        //  - Hermes resolves its skills directory as <HERMES_HOME>/skills with
        //    HERMES_HOME defaulting to ~/.hermes on POSIX, and looks for
        //    <skills dir>/<name>/SKILL.md.
        // Both take the plain home-relative root for the same reason OpenCode
        // does: the alternatives move with an environment variable this
        // installer does not know about.
        case .claudeCode, .cursor, .opencode, .pi, .openclaw, .hermes: return .skillFile
        case .codex: return .appendedBlock
        case .copilot: return .snippet
        }
    }

    enum Scope {
        case global      // one install covers every project on this Mac
        case perProject  // the config lives in the repo, so we can only offer a snippet
    }

    // Falls out of the mechanism rather than being stated twice: a snippet is
    // per-project precisely because we cannot write the file ourselves.
    var scope: Scope {
        switch mechanism {
        case .skillFile, .appendedBlock: return .global
        case .snippet: return .perProject
        }
    }

    // The allowlist dialects we have to speak. Same idea in both — "let the
    // agent run this command without stopping to ask" — spelled differently,
    // and the spelling is load-bearing: an entry that does not match is a
    // permission prompt on the first `listen`, which breaks hands-free on turn
    // one (§6). Both files happen to be JSON with the same
    // `permissions.allow` shape, so only the pattern text differs.
    enum PermissionAllowlist {
        case claudeSettings   // ~/.claude/settings.json, `Bash(…)` patterns
        case cursorCLIConfig  // ~/.cursor/cli-config.json, `Shell(…)` patterns
    }

    // Whether this harness will stop and ask the user before the agent's first
    // `aloud listen` unless we write an allowlist entry.
    //
    // Two of them, and the absences are verified rather than assumed:
    //  - Claude Code: `permissions.allow` in ~/.claude/settings.json.
    //  - Cursor CLI: `permissions.allow` in ~/.cursor/cli-config.json, which on
    //    a real machine already carries entries like `Shell(ls)`. Cursor's row
    //    installed a skill and no allowlist entry until this was noticed, which
    //    is the exact turn-one prompt above.
    //  - OpenCode's built-in agents default to `"*": "allow"`, so bash needs no
    //    entry, and pi's bash tool has no allowlist concept at all.
    //  - OpenClaw has an exec allowlist (~/.openclaw/exec-approvals.json,
    //    `allowedBinaries`), but its documented default security mode for the
    //    hosts that run a shell is `full` — nothing is gated, so there is
    //    nothing to add. Unverified against a live install like the rest of the
    //    OpenClaw row; the cost of being wrong is a prompt on turn one, not a
    //    damaged config, because we do not write the file either way.
    //  - Hermes prompts only for commands its dangerous-pattern detector or its
    //    content scanner flags; anything else is approved without asking. A
    //    plain absolute-path invocation with no shell operators matches
    //    neither, so it never reaches an approval prompt and needs no entry.
    //    Recorded because the format *is* establishable if that ever changes:
    //    a top-level `command_allowlist:` list in ~/.hermes/config.yaml, each
    //    item compared to the whole command by string equality or, when it
    //    contains `*?[`, by case-sensitive fnmatch. We still would not write it
    //    today: it is YAML, we have no YAML parser, and a hand-rolled writer
    //    would break the rule that we never rewrite a config we cannot parse.
    //    So: false, and the uncertainty is the *need*, not the format.
    var permissionAllowlist: PermissionAllowlist? {
        switch self {
        case .claudeCode: return .claudeSettings
        case .cursor: return .cursorCLIConfig
        case .codex, .copilot, .opencode, .pi, .openclaw, .hermes: return nil
        }
    }

    var hasPermissionAllowlist: Bool { permissionAllowlist != nil }

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
        case .opencode:
            // All three exist on a machine that has run OpenCode: the XDG
            // config dir it creates on startup, the ~/.opencode it also scans
            // for config and skills, and the data dir it installs into.
            return [".opencode", ".config/opencode", ".local/share/opencode"]
        case .pi:
            // ~/.pi/agent is where settings.json and auth.json live. A bare
            // ~/.pi is deliberately not the marker: that is also pi's
            // *per-project* config directory name, so a home directory that is
            // itself a project would false-positive.
            return [".pi/agent"]
        case .openclaw:
            // Documentation-derived, and deliberately narrower than the row's
            // own state directory. `~/.openclaw` alone would be a weaker claim
            // than these two, which OpenClaw writes itself: `openclaw.json` is
            // its config file and `workspace` is the seeded agent workspace.
            //
            // What is *not* here matters more. OpenClaw also reads
            // `~/.agents/skills` — and that directory exists on this Mac,
            // populated by an entirely different tool, with no OpenClaw
            // anywhere. Detecting on it would light up the row for anyone who
            // has ever installed any agent skill. That is the `~/.pi/skills`
            // trap again, and it is the reason neither the marker nor the
            // install target is allowed to be a shared, conventional path.
            //
            // Nor is `.openclaw/skills` here: that is where *we* write, so
            // using it as a marker would make a row detect its own install.
            return [".openclaw/openclaw.json", ".openclaw/workspace"]
        case .hermes:
            // Documentation-derived. Hermes' home is ~/.hermes on POSIX
            // (HERMES_HOME overrides it, which this installer cannot follow),
            // and these are two files it creates there rather than the bare
            // directory: config.yaml is its settings file and SOUL.md is the
            // persona file that occupies the first slot in its system prompt.
            // As above, `.hermes/skills` is excluded on purpose — it is our own
            // install target.
            return [".hermes/config.yaml", ".hermes/SOUL.md"]
        }
    }

    // The harness's own *global* instructions file — the one it reads at the
    // start of every session, as opposed to a skill it looks up when it judges
    // one relevant. Home-relative, and documented by each tool rather than
    // guessed, because a wrong path here writes a junk file into somebody's
    // config directory.
    //
    // This is where the one-line nudge goes (`AgentVoiceInstructions.globalNote`).
    // A skill file alone cannot do that job: a skill is *discovered* when the
    // agent already suspects it wants one, and the behaviour we are trying to
    // change — ending the turn and waiting at the keyboard — is the behaviour
    // of an agent that never thought to look.
    //
    // nil means we leave it alone:
    //   - Codex's instructions already live in ~/.codex/AGENTS.md, so the block
    //     we install there IS the global note; a second one would duplicate it.
    //   - Cursor's global rules are a field in its settings UI, not a file.
    //   - OpenClaw and Hermes document skills directories but no global
    //     instructions file, and the shared ~/.agents convention is read by
    //     several tools at once, which is the one place we must not write.
    //   - Copilot is per-project: there is no global anything to write to.
    var globalNotePath: String? {
        switch self {
        case .claudeCode: return ".claude/CLAUDE.md"
        case .opencode: return ".config/opencode/AGENTS.md"
        case .pi: return ".pi/agent/AGENTS.md"
        case .codex, .cursor, .copilot, .openclaw, .hermes: return nil
        }
    }

    // Where the instructions end up. Home-relative for the global pair,
    // repo-relative for the per-project pair.
    var instructionPath: String {
        switch self {
        case .claudeCode: return ".claude/skills/aloud-agent-speak/SKILL.md"
        case .codex: return ".codex/AGENTS.md"
        case .cursor: return ".cursor/skills/aloud-agent-speak/SKILL.md"
        case .copilot: return ".github/copilot-instructions.md"
        // OpenCode also scans ~/.claude/skills and ~/.agents/skills, so a Mac
        // with both Claude Code and OpenCode installed will have two skills
        // named aloud-agent-speak and OpenCode will log a duplicate-name warning.
        // Harmless — the bodies are identical apart from `--harness`, and that
        // flag is a label rather than authentication (§7.1c) — but it is the
        // reason not to be surprised by the warning.
        case .opencode: return ".opencode/skills/aloud-agent-speak/SKILL.md"
        case .pi: return ".pi/agent/skills/aloud-agent-speak/SKILL.md"
        // Documentation-derived, unverified against a live install: OpenClaw's
        // managed skill root is <state-dir>/skills and the state dir defaults
        // to ~/.openclaw. Its higher-precedence roots are the workspace and
        // `~/.agents/skills`; we take neither. The workspace is the user's own
        // memory directory, and `~/.agents` is shared with every other tool
        // that has adopted the convention — writing there would install one
        // file that several harnesses each read under a different `--harness`
        // id, which the id is not equipped to describe.
        case .openclaw: return ".openclaw/skills/aloud-agent-speak/SKILL.md"
        // Documentation-derived, unverified against a live install: Hermes
        // resolves <HERMES_HOME>/skills, HERMES_HOME defaults to ~/.hermes, and
        // a skill is <skills dir>/<name>/SKILL.md. Named profiles get their own
        // home under ~/.hermes/profiles/<profile>/ with their own skills
        // directory, so a user who works inside a non-default profile will not
        // see this skill. Nothing here can fix that without enumerating
        // profiles, which is more than a row in a table.
        case .hermes: return ".hermes/skills/aloud-agent-speak/SKILL.md"
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
    // Our marked block is present but its start/end markers don't pair up —
    // a hand edit or an interrupted write. We cannot tell which lines are ours,
    // so we refuse to rewrite or delete rather than guess and eat the user's
    // own content.
    case damagedBlock(path: String)
    case writeFailed(path: String, message: String)

    var errorDescription: String? {
        switch self {
        case .unreadableSettings(let path, _):
            return "\(path) isn't valid JSON, so Aloud left it alone. Add the permission entries by hand."
        case .damagedBlock(let path):
            return "\(path) has an Aloud section with a broken start/end marker, so Aloud left it alone. Fix or remove that section by hand."
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
    // What the skill is called wherever a harness lists it, and the name the
    // user sees next to it. Matches what the app calls the feature — the two
    // said different things, and the one the user reads in Settings is the one
    // that had to win.
    static let skillDirectory = "aloud-agent-speak"

    static let markerStart = "<!-- aloud-agent-speak:start -->"
    static let markerEnd = "<!-- aloud-agent-speak:end -->"

    // "Agent Speak" is the product name for this capability, and it belongs in
    // every word the user or the agent reads. The CLI verbs below are the wire
    // contract, not branding, and do not move with it.
    //
    // This one string does more work than the rest of the file. A skill body is
    // only read once something decides the skill is relevant, and that decision
    // is made on the description alone — so a description that *describes the
    // feature* is a skill that never loads. It has to name the situations
    // instead: the ones an agent is already in when it is about to end its turn
    // and wait. That is why this reads as a list of triggers rather than a
    // sentence about Aloud, and why the shape ("Use when…") is not decoration.
    static let summary = "Ask the user a question out loud and hear their spoken answer. Use when you need a decision, a choice, an approval, or missing information from the user mid-task and they may not be watching the screen — instead of ending your turn to ask. Triggers: needing to ask the user anything, being blocked on their input, offering options, confirming before something irreversible."

    // What a user says to their agent to get this without waiting for the agent
    // to think of it.
    //
    // Everything else in this file is a nudge: a description shaped to be
    // selected, a note shaped to be obeyed. Nudges are probabilistic, and the
    // user is entitled to a way that simply works — one sentence at the top of
    // a session, and the agent is instructed rather than encouraged. Onboarding
    // shows it and Settings offers it on a Copy button.
    //
    // English, like the skill and the note, and for the same reason: it is read
    // by something reasoning in English. The words *around* it in the UI are
    // localized; this is not.
    static let spokenReplyRequest =
        "Use Aloud to ask me out loud whenever you need my input, instead of ending your turn."

    // The verbs a distributed build exposes (CLI.swift). Also the verbs Claude
    // Code's allowlist has to cover, which is why they live next to the text
    // that teaches them rather than in the installer.
    // Kept in step with `BridgeOperation` by a test, because it drifted:
    // `status` shipped, the skill file teaches it by name and shows the command
    // to run, and it was missing from here — so the allowlist written for the
    // user covered six of the seven verbs, and the first `status` an agent ran
    // stopped for a permission prompt. In the one feature whose whole premise
    // is not having to touch the keyboard.
    static let verbs = ["ask", "wait", "claim", "listen", "speak", "release", "status"]

    // What every Aloud before `ask` put in front of a user. A machine whose
    // allowlist we have written but whose *offered* set we never recorded was
    // installed by one of those versions, so this is what it was shown — and
    // the difference between it and `verbs` is exactly the set that has never
    // been offered to that user at all.
    //
    // Without this the two rules that guard the allowlist contradict each
    // other. "Never re-grant what the user deleted" says a missing entry stays
    // missing; "a skill that teaches a verb the harness will stop and ask
    // about stalls on turn one" says a newly shipped verb must be granted. The
    // entries are identical on disk, so only a record of what was offered can
    // tell a deletion from a verb that did not exist yet.
    static let verbsOfferedBeforeAsk = ["claim", "listen", "speak", "release"]

    // MARK: how the agent types our name
    //
    // One function, and everything that has to agree comes out of it: the
    // sample commands in the instructions, the `Bash(… :*)` patterns in Claude
    // Code's allowlist, and the `Shell(…)` patterns in Cursor CLI's. They only
    // match if they are character-identical, and an allowlist that misses means
    // a permission prompt on the first `listen` — hands-free broken on turn
    // one, the failure §6 warns about. A comment asking three call sites to
    // stay in step is not enough; this is the step.
    static func invocation(command: String) -> String { shellQuoted(command) }

    // The two allowlist spellings, side by side so the difference is visible
    // rather than discovered.
    //
    //  - Claude Code matches the literal *prefix of the whole command line*, so
    //    an entry is `Bash(<invocation> <verb>:*)` and the quoting has to be the
    //    quoting the agent will actually type.
    //  - Cursor CLI matches the *command base* — the first token — with an
    //    optional `:<args glob>` for finer control, so an entry is
    //    `Shell(<invocation>:<verb>*)`. `Shell(<invocation>)` on its own would
    //    also work and is shorter, and is exactly what we do not want: it
    //    permits every argument list forever, including verbs a later Aloud
    //    might add. The args glob keeps the grant the same size as Claude
    //    Code's. Verified against a real ~/.cursor/cli-config.json, which
    //    carries entries in the `Shell(ls)` form — *not* Claude Code's `Bash(…)`.
    static func permissionEntries(style: AgentHarness.PermissionAllowlist,
                                  command: String) -> [String] {
        let invocation = invocation(command: command)
        return verbs.map { verb in
            switch style {
            case .claudeSettings: return "Bash(\(invocation) \(verb):*)"
            case .cursorCLIConfig: return "Shell(\(invocation):\(verb)*)"
            }
        }
    }

    // The command line an entry claims to permit — `<invocation> <verb>` — or
    // nil when the entry is not shaped like one of ours.
    //
    // This is the other half of the single-source rule. Generating the entries
    // from `invocation` is what makes them agree with the instructions;
    // *parsing them back to a command line* is what lets a test prove it,
    // against the bytes on disk, in a way that survives somebody changing the
    // pattern syntax of either dialect.
    static func permittedCommandLine(_ entry: String,
                                     style: AgentHarness.PermissionAllowlist) -> String? {
        switch style {
        case .claudeSettings:
            guard entry.hasPrefix("Bash("), entry.hasSuffix(":*)") else { return nil }
            let inner = String(entry.dropFirst("Bash(".count).dropLast(":*)".count))
            guard let space = inner.lastIndex(of: " ") else { return nil }
            guard verbs.contains(String(inner[inner.index(after: space)...])) else { return nil }
            return inner
        case .cursorCLIConfig:
            guard entry.hasPrefix("Shell("), entry.hasSuffix(")") else { return nil }
            let inner = String(entry.dropFirst("Shell(".count).dropLast(1))
            // Last colon, not first: the invocation is an absolute path and a
            // path is allowed to contain one, while none of our verbs can.
            guard let colon = inner.lastIndex(of: ":") else { return nil }
            let base = String(inner[..<colon])
            // Looser than what we write, on purpose — see `isPermissionEntry`.
            // `listen*`, `listen ` and a bare `listen` all name the same verb.
            let args = String(inner[inner.index(after: colon)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "* \t"))
            guard verbs.contains(args) else { return nil }
            return "\(base) \(args)"
        }
    }

    // Recognising our entries on the way out is deliberately looser than
    // writing them. The allowlist in front of us may have been written by an
    // older Aloud that assumed a bare `aloud` on PATH, or by this one before
    // the user moved the bundle — and an entry we fail to recognise is one we
    // leave behind pointing at a binary that no longer exists. Anything shaped
    // like `<something named aloud> <one of our verbs>` is ours.
    //
    // The name check is what keeps it from being *too* loose: a hand-written
    // `Shell(aloudmixer:listen*)`, or a rule for a verb we do not ship, stays.
    // The verb an entry grants — the last token of its command line — so a
    // migration can carry across exactly the verbs the user still has rather
    // than the whole set. Nil for anything that isn't one of ours.
    static func verb(of entry: String, style: AgentHarness.PermissionAllowlist) -> String? {
        guard let line = permittedCommandLine(entry, style: style),
              let space = line.lastIndex(of: " ") else { return nil }
        return String(line[line.index(after: space)...])
    }

    static func isPermissionEntry(_ entry: String,
                                  style: AgentHarness.PermissionAllowlist) -> Bool {
        guard let line = permittedCommandLine(entry, style: style),
              let space = line.lastIndex(of: " ") else { return false }
        let command = String(line[..<space])
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
        # Agent Speak — asking the user out loud

        Aloud puts a question through the user's speakers and hands you back
        their spoken answer. Reach for it the moment you need a decision you
        cannot make yourself and they may not be watching the screen — instead
        of ending your turn and leaving them to find out at the keyboard.

        ## One call

        ```sh
        \#(command) ask --harness \#(id) --owner-pid $PPID --name "fixing tests" --end \
          "The migration test is failing. Roll it back, or fix it forward?"
        # {"cleanup":"concise","ok":true,"text":"fix it forward","v":1}
        ```

        That is the whole thing. `--end` speaks, listens and hangs up in one
        command. Leave it off and the answer comes back with a `lease` to carry:

        ```sh
        \#(command) ask --lease L1 "Same for the staging migration?"   # no second prompt
        # {"cleanup":"concise","lease":"L1","ok":true,"text":"yes","v":1}
        \#(command) release --lease L1                                 # when you are done
        ```

        - `--harness \#(id)` and `--name` open a session and are both required
          to; a claim without a name is refused. The name says what you are
          *doing* — "fixing tests", "release notes" — because the user reads it
          on the indicator, hears it in the spoken prompt, and picks from it
          when two windows of the same tool both want the microphone.
          **At most 2 words and 28 characters**, or the call comes back
          `badRequest` — it has to fit in a spoken sentence and on a button.
          Neither flag is needed once you hold a lease; re-send `--name` if the
          job has moved on.
        - `--owner-pid $PPID`, exactly as written, whenever you open a session.
          It tells your window apart from another window of the same tool, and
          frees the microphone the moment you exit rather than at the timeout.
        - **`ask` blocks** — on the user's consent, then on their answer. Give
          it a generous timeout and do not race it.

        ## `--hold`: when they may not be at the desk

        `ask` gives up after a few seconds of silence. `--hold <seconds>` (600
        max) keeps the same session open that long instead: it listens normally
        first, and only if nobody answers does the indicator change to say it is
        still waiting. It returns the moment anyone speaks, with `waited` saying
        how long it sat there.

        ```sh
        \#(command) ask --harness \#(id) --owner-pid $PPID --name "fixing tests" \
          --hold 600 --end "Roll the migration back, or fix it forward?"
        # {"cleanup":"concise","ok":true,"text":"fix it forward","v":1,"waited":252}
        ```

        **Run it in a background shell and end your turn.** It costs one turn to
        start and one when it returns, nothing in between, and you are woken
        with the answer. If your harness has no background shell, run it in the
        foreground with a `--hold` comfortably inside your own command timeout —
        shorter, but it still waits.

        A large `waited` means real time has passed. Check your plan still holds
        before acting on the answer.

        `wait` is the same thing without saying anything, for when the question
        has already been asked and the answer has not come: `\#(command) wait
        --lease L1 --end`. It differs from `ask` in two ways, both because it
        has already been told nobody is there — it holds for the full 600
        seconds unless `--hold` says otherwise, and if the microphone is busy it
        queues for it instead of coming straight back `queued`. Opening a
        session with it takes the same `--harness` and `--name` as `ask`.

        ## How to behave

        **One or two sentences, question last.** Not "what do you think?" —
        "the migration test is failing, should I roll it back or fix it
        forward?" Enough to answer without switching windows. Everything you
        send is also on screen word for word, so send the finished sentence,
        not the reasoning that got you there.

        **Never narrate.** This is for decisions, not progress reports.

        **Honour "stop telling me every time."** If the user asks you to drop
        the preamble, drop it for the rest of the session and do not drift back.

        **A refusal is an answer, not a bug.** The user can switch this off or
        decline at any moment. Fall back to text and carry on — never retry in
        a loop.

        | refusal | what it means | what to do |
        |---|---|---|
        | `disabled` | switched off in Aloud | stop asking for the rest of the session |
        | `denied` | the user declined this request | text now; later is fine |
        | `timeout` | nobody answered, or nobody spoke | text; do not immediately re-ask |
        | `queued` | somebody else has the microphone, it is settling, or the user is dictating | if `queuedBehind` names another agent, use text; if `message` says the user is dictating, they are right there and about to be free, so retry once after `retryAfter` — or pass `--wait 30` and it rides their dictation out for you; otherwise wait `retryAfter` and try once |
        | `notHolder` | the lease ended — released, reaped, superseded | open a new session if you still need to ask |
        | `unavailable` | Aloud isn't running or couldn't answer — read `message` | text; the one refusal that also exits non-zero |
        | `badRequest` | a flag is missing or invalid — `message` says which | fix it and call again; your bug, not a refusal |

        `text` is the answer and the only text you get: the best cleanup this
        Mac can do, at the tier `cleanup` names (`"basic"` is closer to a raw
        transcript than a tidied sentence). There is deliberately no verbatim
        copy beside it — the same sentence twice is double the tokens for
        something you would not act on differently.

        ## The rest of the surface

        `ask` is `claim` + `speak` + `listen` in one call. The three still exist
        for the one case that needs them: cutting in before the user has
        finished talking. Every poll costs you a turn, so use it deliberately.

        ```sh
        \#(command) claim  --harness \#(id) --owner-pid $PPID --name "code review"
        # {"lease":"L1","ok":true,"v":1}
        \#(command) speak  --lease L1 "Which of the two should I take first?"
        \#(command) listen --start --lease L1        # {"ok":true,"session":"S1","v":1}
        \#(command) listen --poll  --lease L1 --session S1 --wait 5
        # {"ok":true,"session":"S1","silentFor":0.4,"speaking":true,"text":"…","v":1}
        \#(command) listen --stop  --lease L1 --session S1
        ```

        `listen` with no mode blocks and ends on silence. `--wait` is the
        long-poll ceiling in seconds (5 by default, 30 at most) and returns
        early the moment the transcript changes; `speaking` and `silentFor` are
        what you judge "heard enough" on. `claim --wait <seconds>` (300 at most)
        blocks until the microphone is free — the only supported way to queue,
        and it costs no turns. Always `release`: a lease nobody releases keeps
        the microphone from everyone else until it times out.

        `status` is the seventh and last verb. It never opens the microphone and
        answers exactly two things — whether the feature is switched on, and who
        holds the microphone if anyone does:

        ```sh
        \#(command) status      # {"enabled":true,"holder":"codex","ok":true,"v":1}
        ```

        You should rarely need it: every verb already refuses with `disabled`
        when the feature is off, which is the same news a turn earlier. There is
        nothing else to ask Aloud about — which voice speaks and how fast are
        the user's settings, not yours, and nothing on this socket will tell you
        or let you change them.
        """#
    }

    // The whole file, for harnesses where we own the file.
    static func skillFile(harness: AgentHarness, command: String) -> String {
        let frontmatter = """
        ---
        name: aloud-agent-speak
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

    // MARK: the global note
    //
    // Its own marker pair, because it lives in a different file from the
    // instructions and the two are installed and removed independently: one
    // marker for both would make a note in ~/.claude/CLAUDE.md look like a
    // damaged instructions block in ~/.claude/skills/…/SKILL.md.
    static let noteMarkerStart = "<!-- aloud-agent-speak-note:start -->"
    static let noteMarkerEnd = "<!-- aloud-agent-speak-note:end -->"

    // Three sentences at most, and they have to earn their place in a file the
    // user wrote for themselves. So: what is available, when to reach for it,
    // and where the detail lives — never the mechanics, which are in the skill.
    //
    // The point of the last sentence is the whole point of the feature. An
    // agent's default when it needs a decision is to stop and hand the turn
    // back, and someone who has walked away from the keyboard doesn't find out
    // for ten minutes. This is the line that changes that default.
    // `harness` for the same reason `body` takes one: the note now carries a
    // runnable command, and a command carrying the wrong `--harness` labels the
    // session on the user's own indicator with the name of a tool they are not
    // running.
    static func globalNote(harness: AgentHarness, command: String) -> String {
        let id = harness.id
        let command = invocation(command: command)
        // Written as an instruction, not a description. The earlier version
        // said what Aloud could do and left the agent to infer that it should;
        // an agent reading a global instructions file acts on directives and
        // skims capabilities. So: the rule first, in the imperative, and the
        // command it takes right there — a note that costs a lookup to act on
        // is a note that gets deferred until after the turn has ended, which is
        // the exact failure it exists to prevent.
        return """
        ## Asking the user out loud (Aloud)

        **When you need something from the user mid-task — a decision, a \
        choice between options, an approval, a missing detail — ask them out \
        loud instead of ending your turn.** They are often not at the screen, \
        and a turn that ends with a question can sit unread for an hour.

        ```sh
        \(command) ask --harness \(id) --owner-pid $PPID --name "<two words>" --end "<your question>"
        # {"cleanup":"concise","ok":true,"text":"their answer","v":1}
        ```

        One command: it speaks, listens, and returns what they said. Keep the \
        question to a sentence or two. If it comes back `"ok":false`, that is a \
        normal answer — ask in text and carry on, never retry in a loop. Full \
        details, including follow-up questions in the same session, are in the \
        `aloud-agent-speak` skill.
        """
    }

    static func markedNote(_ inner: String) -> String {
        "\(noteMarkerStart)\n\(inner)\n\(noteMarkerEnd)\n"
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
    func permissionEntries(for harness: AgentHarness) -> [String] {
        guard let style = harness.permissionAllowlist else { return [] }
        return AgentVoiceInstructions.permissionEntries(style: style, command: command)
    }

    var claudePermissionEntries: [String] { permissionEntries(for: .claudeCode) }
    var cursorPermissionEntries: [String] { permissionEntries(for: .cursor) }

    // Where "the user took this one away" is remembered. Injected so tests get
    // their own suite; see `declinedHarnesses`.
    let defaults: UserDefaults

    init(home: URL,
         command: String = HarnessInstaller.defaultCommand,
         fileManager: FileManager = .default,
         defaults: UserDefaults = .standard) {
        self.home = home
        self.command = command
        self.fm = fileManager
        self.defaults = defaults
    }

    // Every installer operation runs one at a time, whichever thread asks.
    //
    // Two can now genuinely overlap: the launch and gate-toggle refresh was
    // moved off the main thread, while the Settings pane drives the same
    // installer from the main one. They share the user's config files *and*
    // the UserDefaults lists that decide what may be written — and those lists
    // are read-modify-write, so a lost update means a harness the user removed
    // is quietly reinstalled by the next update, which is the one thing the
    // record of removals exists to prevent. Recursive because these entry
    // points call one another.
    private static let sequencing = NSRecursiveLock()

    private func serialized<T>(_ body: () throws -> T) rethrows -> T {
        Self.sequencing.lock(); defer { Self.sequencing.unlock() }
        return try body()
    }

    // MARK: what the user took away
    //
    // Installing on every update is what gets the feature to people who never
    // opened Settings. It is also, without this list, a way to overrule someone:
    // they removed the skill from a harness on purpose, and the next launch put
    // it back. So a removal is recorded, and the automatic install skips it
    // forever after. An install the user asks for clears the record — that is
    // them changing their mind, which they are allowed to do.
    private static let declinedKey = "agentDeclinedHarnesses"

    var declinedHarnesses: Set<String> {
        Set(defaults.stringArray(forKey: Self.declinedKey) ?? [])
    }

    func recordDeclined(_ harness: AgentHarness) {
        serialized {
            var declined = declinedHarnesses
            declined.insert(harness.id)
            defaults.set(Array(declined).sorted(), forKey: Self.declinedKey)
        }
    }

    func clearDeclined(_ harness: AgentHarness) {
        serialized {
            var declined = declinedHarnesses
            guard declined.remove(harness.id) != nil else { return }
            defaults.set(Array(declined).sorted(), forKey: Self.declinedKey)
        }
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

    // Bring every installed harness's instructions up to date.
    //
    // `isInstalled` answers on the presence of our marker, not on what the
    // marker contains — which is the right question for "did the user opt in",
    // and the wrong one for "is this current". Without this, an Aloud update
    // that changes what agents are told leaves every already-installed harness
    // running the old text forever, reported in the pane as "Installed" and
    // looking entirely healthy. That is how a harness ends up passing a flag
    // that no longer exists, or omitting one that now matters.
    //
    // Deliberately just `install` again rather than a parallel refresh path:
    // it already replaces our block in place and writes only when the content
    // differs, so an unchanged harness costs a read and touches nothing.
    //
    // A refresh runs on every launch and every gate toggle, so it must never
    // re-grant a permission the user took away: "entry not present" is
    // indistinguishable from "revoked". Full permission entries are written
    // exactly once, by an install rather than a refresh — the one the user
    // clicked, or the automatic first install into a harness they have never
    // removed (`installAllDetected`), which needs them for the same reason: a
    // harness that is told to run the CLI and not allowed to stalls on the
    // turn-one permission prompt. The one thing a refresh
    // does to the allowlist is `.migrate` — following the entries to a new
    // path when the bundle moved, carrying across only the verbs still there,
    // never adding one back. And that step is best-effort: a corrupt
    // settings.json is skipped so it cannot block the instruction update the
    // refresh is really for.
    @discardableResult
    func refreshInstalled() -> [AgentHarness] {
        serialized {
            // Before anything is refreshed, so an install written under the old
            // name is gone rather than sitting beside the new one.
            removeLegacyNamedInstalls()
            return AgentHarness.allCases.filter { harness in
                guard harness.scope == .global, isInstalled(harness) else { return false }
                guard case .installed(let changed)? = try? install(harness, permissions: .migrate)
                else { return false }
                return !changed.isEmpty
            }
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

    // Driven by the mechanism, not by the harness, so a new row in the table
    // installs without a new branch here. `permissions: false` is the refresh
    // path: update what the agent is told, leave what the agent is allowed
    // strictly alone.
    func install(_ harness: AgentHarness, permissions: AllowlistOp = .add) throws -> InstallResult {
        Self.sequencing.lock(); defer { Self.sequencing.unlock() }
        let block = AgentVoiceInstructions.markedBlock(
            AgentVoiceInstructions.body(harness: harness, command: command))

        switch harness.mechanism {
        case .snippet:
            return .snippet(ProjectSnippet(harness: harness,
                                           relativePath: harness.instructionPath,
                                           contents: block))

        case .appendedBlock:
            let url = home.appendingPathComponent(harness.instructionPath)
            var changed: [URL] = []
            if try upsertBlock(block, in: url) { changed.append(url) }
            changed.append(contentsOf: try installGlobalNote(for: harness, op: permissions))
            // Only an install the user asked for is them changing their
            // mind. A refresh runs on every launch and must not be read as
            // consent — that path would quietly erase the removal record and
            // let a later version reinstall what they took away.
            if permissions != .migrate { clearDeclined(harness) }
            return .installed(changed: changed)

        case .skillFile:
            var changed: [URL] = []
            // Allowlist first, skill second. On a user install (`.add`) the
            // permission file is mandatory and parsed before the skill is
            // written, so a corrupt file aborts cleanly and the click retries
            // rather than leaving a skill present with its permission entry
            // missing (which looks installed and prompts on turn one).
            //
            // On a refresh (`.migrate`) it is best-effort: bringing the
            // instructions up to date must not be held hostage by a
            // temporarily-broken settings.json the user or another tool left,
            // so a throw here is swallowed and the skill is still written.
            if let allowlist = allowlistURL(for: harness) {
                do {
                    if let data = try allowlistJSON(at: allowlist, for: harness, op: permissions) {
                        try write(data, to: allowlist)
                        changed.append(allowlist)
                    }
                    // Recorded on the success path only, and after the write
                    // rather than before: this is the memory that stops the
                    // next refresh re-offering a verb the user has now had the
                    // chance to delete. Set on a no-op write too — "nothing to
                    // change" still means the entries are in front of them.
                    recordOffered(AgentVoiceInstructions.verbs, for: harness)
                } catch {
                    if permissions != .migrate { throw error }
                }
            }
            let skill = home.appendingPathComponent(harness.instructionPath)
            let file = AgentVoiceInstructions.skillFile(harness: harness, command: command)
            if try writeIfDifferent(file, to: skill) { changed.append(skill) }
            changed.append(contentsOf: try installGlobalNote(for: harness, op: permissions))
            // Only an install the user asked for is them changing their
            // mind. A refresh runs on every launch and must not be read as
            // consent — that path would quietly erase the removal record and
            // let a later version reinstall what they took away.
            if permissions != .migrate { clearDeclined(harness) }
            return .installed(changed: changed)
        }
    }

    // The one-line nudge in the harness's own global instructions, for the
    // harnesses that have such a file. Written with its own marker so it can be
    // taken out again exactly, and treated as best-effort: a global
    // instructions file the user has damaged our markers in must not block the
    // skill install, which is the part that actually carries the contract.
    private func installGlobalNote(for harness: AgentHarness, op: AllowlistOp) throws -> [URL] {
        guard let path = harness.globalNotePath else { return [] }
        let url = home.appendingPathComponent(path)
        // Never conjure the directory. OpenCode's global instructions live
        // under ~/.config/opencode, which moves with XDG_CONFIG_HOME — the very
        // reason its *skill* goes to the plain ~/.opencode instead. On a Mac
        // that has relocated its XDG config, creating the directory would leave
        // a file OpenCode never reads and a folder we invented. If the harness
        // keeps its instructions somewhere else, it has told us so by not
        // having this directory.
        guard exists(url.deletingLastPathComponent()) else { return [] }
        // A refresh may update a note that is there, and may write the very
        // first one — but it may never put back a note the user deleted.
        //
        // Those are the same bytes on disk, so the difference is remembered:
        // the first time a harness gets a note, its id goes in the list below.
        // Without that, the two halves of this feature contradict each other.
        // Every existing user already has the skill installed, so the automatic
        // install skips them entirely and the refresh is the only pass that
        // ever touches their machine — if a refresh could not write a note,
        // nobody who already had Agent Speak would ever get one. And if it
        // wrote one unconditionally, deleting our paragraph from a curated
        // CLAUDE.md would buy exactly one session of peace before the next
        // launch put it back. Same rule the allowlist follows, one bit richer.
        if op == .migrate, noteWasWritten(for: harness) {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains(AgentVoiceInstructions.noteMarkerStart)
            else { return [] }
        }
        let note = AgentVoiceInstructions.markedNote(
            AgentVoiceInstructions.globalNote(harness: harness, command: command))
        do {
            let changed = try upsertBlock(note,
                                          in: url,
                                          start: AgentVoiceInstructions.noteMarkerStart,
                                          end: AgentVoiceInstructions.noteMarkerEnd)
            recordNoteWritten(for: harness)
            return changed ? [url] : []
        } catch {
            return []
        }
    }

    // Whether this harness has ever had a note written into its global
    // instructions — the one bit that separates "we have not got to you yet"
    // from "you took it out".
    private static let noteWrittenKey = "agentGlobalNoteWritten"

    private func noteWasWritten(for harness: AgentHarness) -> Bool {
        (defaults.stringArray(forKey: Self.noteWrittenKey) ?? []).contains(harness.id)
    }

    private func recordNoteWritten(for harness: AgentHarness) {
        var written = Set(defaults.stringArray(forKey: Self.noteWrittenKey) ?? [])
        guard written.insert(harness.id).inserted else { return }
        defaults.set(Array(written).sorted(), forKey: Self.noteWrittenKey)
    }

    // MARK: which verbs this harness has been offered
    //
    // The companion to `declinedHarnesses`, one level down: that remembers a
    // whole harness the user took away, this remembers which individual
    // permission entries they have ever been given the chance to keep. Stored
    // as "<harness>/<verb>" so one flat list covers every row.
    private static let offeredVerbsKey = "agentOfferedVerbs"

    // Falls back to the pre-`ask` set rather than to empty. Empty would mean
    // "offer them everything", which on the first launch after this change is
    // precisely the machine where the user's deletions are invisible to us —
    // so it would hand back every entry anyone had ever removed.
    private func offeredVerbs(for harness: AgentHarness) -> Set<String> {
        let stored = defaults.stringArray(forKey: Self.offeredVerbsKey) ?? []
        let prefix = "\(harness.id)/"
        let recorded = stored.filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
        return recorded.isEmpty ? Set(AgentVoiceInstructions.verbsOfferedBeforeAsk)
                                : Set(recorded)
    }

    // Called only where the allowlist was actually dealt with successfully. A
    // corrupt settings.json we skipped must not be recorded as "they have seen
    // `ask`" — the next launch is the retry, and this is what would stop it.
    private func recordOffered(_ verbs: [String], for harness: AgentHarness) {
        var stored = Set(defaults.stringArray(forKey: Self.offeredVerbsKey) ?? [])
        let before = stored.count
        for verb in verbs { stored.insert("\(harness.id)/\(verb)") }
        guard stored.count != before else { return }
        defaults.set(Array(stored).sorted(), forKey: Self.offeredVerbsKey)
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
        Self.sequencing.lock(); defer { Self.sequencing.unlock() }
        // Recorded first, and whatever the rest of this throws: the user has
        // said no, and the automatic install on the next update must honour
        // that even if the removal itself hit a damaged file.
        recordDeclined(harness)

        switch harness.mechanism {
        case .snippet:
            return  // nothing of ours is on disk to remove

        case .appendedBlock:
            try? removeGlobalNote(for: harness)
            try removeBlock(from: home.appendingPathComponent(harness.instructionPath))

        case .skillFile:
            try removeSkillDirectory(at: home.appendingPathComponent(harness.instructionPath))
            // The note is taken out after the skill and never before it, and a
            // damaged one is swallowed rather than thrown. It lives in a file
            // the user edits by hand — one orphaned marker in CLAUDE.md used to
            // abort the whole uninstall, leaving the skill installed and four
            // shell permissions granted for a feature the user just removed.
            // The note is the least important thing here; it may not be the
            // thing that blocks removing the rest.
            do {
                try removeGlobalNote(for: harness)
            } catch {
                // Swallowed, but not unrecorded: the paragraph telling agents
                // to use Agent Speak is still sitting in the user's own file
                // after they removed the feature, and the only way anyone finds
                // out is a developer reading this log.
                DevDiag.note("install", "left the note in place: \(error.localizedDescription)")
            }
            // The skill file goes first and unconditionally, so a harness with
            // no allowlist is finished here and the ones that have an allowlist
            // still lose their skill even if the settings step throws.
            guard let allowlist = allowlistURL(for: harness) else { return }
            // A malformed config on the way out is still not ours to rewrite —
            // surface it so the pane can say the allowlist is stale.
            if let data = try allowlistJSON(at: allowlist, for: harness, op: .remove) {
                try write(data, to: allowlist)
            }
            removeBackup(of: allowlist)
        }
    }

    // MARK: - the old name

    // What Aloud called this before it was called Agent Speak.
    //
    // The skill, the marker around the block in an AGENTS.md, and the note in a
    // CLAUDE.md all carried `aloud-voice` while the app itself said "Agent
    // Speak" everywhere the user could see. Renaming without this would leave
    // every existing install carrying both: a stale `aloud-voice` skill
    // teaching the same seven verbs beside the new one, and a duplicated block
    // in files the user has open every day. So the old name is not just
    // replaced, it is cleaned up — once, quietly, on the first launch after the
    // update.
    enum LegacyNames {
        static let skillDirectory = "aloud-voice"
        static let markerStart = "<!-- aloud-voice:start -->"
        static let markerEnd = "<!-- aloud-voice:end -->"
        static let noteMarkerStart = "<!-- aloud-voice-note:start -->"
        static let noteMarkerEnd = "<!-- aloud-voice-note:end -->"
    }

    // Take out anything an earlier Aloud installed under the old name. Guarded
    // by the old marker exactly as the uninstaller is: a file that happens to
    // share the name but was not written by us is not ours to remove.
    func removeLegacyNamedInstalls() {
        for harness in AgentHarness.allCases {
            let path = harness.instructionPath
            let legacy = path.replacingOccurrences(
                of: "skills/\(AgentVoiceInstructions.skillDirectory)/",
                with: "skills/\(LegacyNames.skillDirectory)/")
            if legacy != path {
                removeLegacySkill(at: home.appendingPathComponent(legacy))
            } else if harness.mechanism == .appendedBlock {
                try? removeBlock(from: home.appendingPathComponent(path),
                                 start: LegacyNames.markerStart,
                                 end: LegacyNames.markerEnd)
            }
            if let note = harness.globalNotePath {
                try? removeBlock(from: home.appendingPathComponent(note),
                                 start: LegacyNames.noteMarkerStart,
                                 end: LegacyNames.noteMarkerEnd)
            }
        }
    }

    private func removeLegacySkill(at skill: URL) {
        guard let text = try? String(contentsOf: skill, encoding: .utf8),
              text.contains(LegacyNames.markerStart) else { return }
        try? fm.removeItem(at: skill)
        removeBackup(of: skill)
        let dir = skill.deletingLastPathComponent()
        if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
            try? fm.removeItem(at: dir)
        }
    }

    // The note comes out the way it went in: our marker only, everything the
    // user wrote around it untouched, and a file that held nothing but our note
    // deleted rather than left empty.
    private func removeGlobalNote(for harness: AgentHarness) throws {
        guard let path = harness.globalNotePath else { return }
        try removeBlock(from: home.appendingPathComponent(path),
                        start: AgentVoiceInstructions.noteMarkerStart,
                        end: AgentVoiceInstructions.noteMarkerEnd)
    }

    // MARK: - installing without being asked

    // Every harness on this Mac that we can write to, has not been installed
    // already, and the user has not taken away. Returns the ones that changed.
    //
    // This is what makes the feature real for someone who updates and never
    // opens Settings: the instructions are the whole mechanism by which an
    // agent learns the bridge exists, and an agent that was never told simply
    // never calls it. The permission entries go in with it — an install that
    // teaches the agent to run a command the harness will then stop and ask
    // about is a feature that stalls on turn one.
    //
    // Per-project harnesses are skipped by construction: `install` hands back a
    // snippet for those, and nothing here may write into somebody's repo.
    @discardableResult
    func installAllDetected() -> [AgentHarness] {
        Self.sequencing.lock(); defer { Self.sequencing.unlock() }
        let declined = declinedHarnesses
        return detect().compactMap { detected -> AgentHarness? in
            let harness = detected.harness
            guard harness.scope == .global,
                  !detected.isInstalled,
                  !declined.contains(harness.id),
                  case .installed(let changed)? = try? install(harness)
            else { return nil }
            return changed.isEmpty ? nil : harness
        }
    }

    // MARK: - permission allowlists

    // Both dialects live in a JSON file with a `permissions.allow` array, which
    // is why one reader/writer serves both. Only the pattern text differs, and
    // that difference is `AgentVoiceInstructions`' business, not this one's.
    var claudeSettingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    var cursorCLIConfigURL: URL { home.appendingPathComponent(".cursor/cli-config.json") }

    func allowlistURL(for harness: AgentHarness) -> URL? {
        switch harness.permissionAllowlist {
        case .claudeSettings: return claudeSettingsURL
        case .cursorCLIConfig: return cursorCLIConfigURL
        case nil: return nil
        }
    }

    // Returns the bytes to write, or nil when nothing needs changing — which is
    // what makes a second install byte-identical rather than merely equivalent.
    // Throws rather than writing if the file is not JSON we understand.
    // What a write to the allowlist is doing. `add` is the user's install;
    // `remove` is uninstall; `migrate` is the launch-time refresh, which
    // follows the binary if it moved but never re-grants an entry the user
    // took away.
    enum AllowlistOp { case add, remove, migrate }

    private func allowlistJSON(at url: URL,
                               for harness: AgentHarness,
                               op: AllowlistOp) throws -> Data? {
        let adding = (op == .add)
        guard let style = harness.permissionAllowlist else { return nil }
        let snippet = permissionSnippet(for: harness)
        var root: [String: Any] = [:]
        if fm.fileExists(atPath: url.path) {
            // A file that exists but will not read (permissions, an ACL) is not
            // the same as no file. Treating it as absent would let the atomic
            // write below replace the user's whole settings with just our four
            // entries — so refuse it exactly as we refuse unparseable JSON.
            guard let data = try? Data(contentsOf: url) else {
                throw HarnessInstallError.unreadableSettings(path: url.path,
                                                             snippet: snippet)
            }
            guard let parsed = try? JSONSerialization.jsonObject(with: data),
                  let object = parsed as? [String: Any] else {
                throw HarnessInstallError.unreadableSettings(path: url.path,
                                                             snippet: snippet)
            }
            root = object
        } else if !adding {
            return nil  // no file, nothing to take out
        }

        var permissions: [String: Any] = [:]
        if let existing = root["permissions"] {
            guard let object = existing as? [String: Any] else {
                throw HarnessInstallError.unreadableSettings(path: url.path,
                                                             snippet: snippet)
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
                                                             snippet: snippet)
            }
            allow = list
        }

        let currentEntries = permissionEntries(for: harness)
        var changed = false
        switch op {
        case .add:
            let present = Set(allow.compactMap { $0 as? String })
            for entry in currentEntries where !present.contains(entry) {
                allow.append(entry)
                changed = true
            }
        case .remove:
            let before = allow.count
            allow.removeAll { element in
                guard let entry = element as? String else { return false }
                return AgentVoiceInstructions.isPermissionEntry(entry, style: style)
            }
            changed = allow.count != before
        case .migrate:
            // Only follow a moved bundle — never re-grant a revoked entry.
            // Every Aloud entry we already wrote matches `isPermissionEntry`
            // whatever its path; the tell for "moved" is that none of them are
            // at the CURRENT path. If any current-path entry is present the
            // install lives here (perhaps with some entries the user
            // deliberately deleted), and we leave it exactly as it is.
            let ours = allow.compactMap { $0 as? String }
                .filter { AgentVoiceInstructions.isPermissionEntry($0, style: style) }
            let currentSet = Set(currentEntries)
            if !ours.isEmpty, !ours.contains(where: { currentSet.contains($0) }) {
                // Carry across exactly the verbs the user still has, not the
                // whole set: someone who deleted `speak` and then moved the
                // bundle must not have `speak` handed back by the migration.
                let keptVerbs = Set(ours.compactMap { AgentVoiceInstructions.verb(of: $0, style: style) })
                let migrated = currentEntries.filter { entry in
                    AgentVoiceInstructions.verb(of: entry, style: style).map(keptVerbs.contains) ?? false
                }
                allow.removeAll { element in
                    guard let entry = element as? String else { return false }
                    return AgentVoiceInstructions.isPermissionEntry(entry, style: style)
                }
                allow.append(contentsOf: migrated)
                changed = true
            }
            // A verb this Aloud ships that the last one did not. The user has
            // never seen it, so there is nothing of theirs to overrule — and
            // the refresh has just rewritten their skill file to teach it. A
            // verb taught and not permitted is the turn-one permission prompt
            // the whole allowlist exists to avoid, and it would land on the
            // one call the feature is now built around.
            //
            // Scoped to genuinely-new verbs by `offeredVerbs`, so this can
            // never become a back door that hands back `speak` to somebody who
            // deleted it.
            let neverOffered = Set(AgentVoiceInstructions.verbs)
                .subtracting(offeredVerbs(for: harness))
            if !neverOffered.isEmpty {
                let present = Set(allow.compactMap { $0 as? String })
                for entry in currentEntries where !present.contains(entry) {
                    guard let verb = AgentVoiceInstructions.verb(of: entry, style: style),
                          neverOffered.contains(verb) else { continue }
                    allow.append(entry)
                    changed = true
                }
            }
        }
        guard changed else { return nil }

        permissions["allow"] = allow
        root["permissions"] = permissions
        return try JSONSerialization.data(withJSONObject: root,
                                          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // What we offer when we refuse to touch a config we could not parse. Both
    // dialects nest the same way, so only the entries inside differ.
    func permissionSnippet(for harness: AgentHarness) -> String {
        let entries = permissionEntries(for: harness).map { "    \"\($0)\"" }.joined(separator: ",\n")
        return "\"permissions\": {\n  \"allow\": [\n\(entries)\n  ]\n}"
    }

    var permissionSnippet: String { permissionSnippet(for: .claudeCode) }

    // MARK: - markdown blocks

    // Insert our block, or replace the one already there. Returns whether the
    // file changed, so a repeat install reports honestly instead of claiming a
    // write it never made.
    private func upsertBlock(_ block: String,
                             in url: URL,
                             start: String = AgentVoiceInstructions.markerStart,
                             end: String = AgentVoiceInstructions.markerEnd) throws -> Bool {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated: String
        if existing.contains(start) {
            // Strip whatever we wrote before, then write one block. If the
            // strip could not run — a damaged or orphaned marker — appending
            // would stack a second block on top, and since a refresh runs
            // every launch the file would grow without bound. Refuse instead;
            // the pane surfaces it, and `refreshInstalled` skips it quietly.
            guard let stripped = removingBlock(from: existing, start: start, end: end) else {
                throw HarnessInstallError.damagedBlock(path: url.path)
            }
            if stripped.isEmpty {
                updated = block
            } else {
                let separator = stripped.hasSuffix("\n") ? "\n" : "\n\n"
                updated = stripped + separator + block
            }
        } else if existing.isEmpty {
            updated = block
        } else {
            let separator = existing.hasSuffix("\n") ? "\n" : "\n\n"
            updated = existing + separator + block
        }
        return try writeIfDifferent(updated, to: url)
    }

    private func removeBlock(from url: URL,
                             start: String = AgentVoiceInstructions.markerStart,
                             end: String = AgentVoiceInstructions.markerEnd) throws {
        guard let existing = try? String(contentsOf: url, encoding: .utf8),
              existing.contains(start) else { return }
        guard let stripped = removingBlock(from: existing, start: start, end: end) else {
            // Damaged markers — we cannot prove which lines are ours, so we
            // touch neither the file nor the user's pre-Aloud backup.
            throw HarnessInstallError.damagedBlock(path: url.path)
        }
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

    // Removes EVERY well-formed block we wrote, line-based so a stray marker
    // inside a code fence cannot swallow half the file and so the blank line we
    // inserted with a block comes back out with it. Returns nil — refusing the
    // whole edit — if any start marker cannot be cleanly paired with an end
    // (an orphan, or a start nested inside another block's span): a file we
    // cannot parse with certainty is not one to guess at.
    private func removingBlock(from text: String,
                               start startMarker: String = AgentVoiceInstructions.markerStart,
                               end endMarker: String = AgentVoiceInstructions.markerEnd) -> String? {
        func trimmed(_ line: String) -> String { line.trimmingCharacters(in: .whitespaces) }
        var lines = text.components(separatedBy: "\n")
        while let start = lines.firstIndex(where: { trimmed($0) == startMarker }) {
            guard let end = lines[start...].firstIndex(where: { trimmed($0) == endMarker })
            else { return nil }
            guard !lines[(start + 1)..<end].contains(where: { trimmed($0) == startMarker })
            else { return nil }

            lines.removeSubrange(start...end)
            // Collapse the separator blank line we added on the way in.
            if start > 0, start < lines.count, lines[start - 1].isEmpty, lines[start].isEmpty {
                lines.remove(at: start)
            } else if start > 0, start == lines.count, lines[start - 1].isEmpty {
                lines.removeLast()
            }
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
