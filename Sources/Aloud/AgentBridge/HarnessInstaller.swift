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

    // Where the instructions end up. Home-relative for the global pair,
    // repo-relative for the per-project pair.
    var instructionPath: String {
        switch self {
        case .claudeCode: return ".claude/skills/aloud-voice/SKILL.md"
        case .codex: return ".codex/AGENTS.md"
        case .cursor: return ".cursor/skills/aloud-voice/SKILL.md"
        case .copilot: return ".github/copilot-instructions.md"
        // OpenCode also scans ~/.claude/skills and ~/.agents/skills, so a Mac
        // with both Claude Code and OpenCode installed will have two skills
        // named aloud-voice and OpenCode will log a duplicate-name warning.
        // Harmless — the bodies are identical apart from `--harness`, and that
        // flag is a label rather than authentication (§7.1c) — but it is the
        // reason not to be surprised by the warning.
        case .opencode: return ".opencode/skills/aloud-voice/SKILL.md"
        case .pi: return ".pi/agent/skills/aloud-voice/SKILL.md"
        // Documentation-derived, unverified against a live install: OpenClaw's
        // managed skill root is <state-dir>/skills and the state dir defaults
        // to ~/.openclaw. Its higher-precedence roots are the workspace and
        // `~/.agents/skills`; we take neither. The workspace is the user's own
        // memory directory, and `~/.agents` is shared with every other tool
        // that has adopted the convention — writing there would install one
        // file that several harnesses each read under a different `--harness`
        // id, which the id is not equipped to describe.
        case .openclaw: return ".openclaw/skills/aloud-voice/SKILL.md"
        // Documentation-derived, unverified against a live install: Hermes
        // resolves <HERMES_HOME>/skills, HERMES_HOME defaults to ~/.hermes, and
        // a skill is <skills dir>/<name>/SKILL.md. Named profiles get their own
        // home under ~/.hermes/profiles/<profile>/ with their own skills
        // directory, so a user who works inside a non-default profile will not
        // see this skill. Nothing here can fix that without enumerating
        // profiles, which is more than a row in a table.
        case .hermes: return ".hermes/skills/aloud-voice/SKILL.md"
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
    static let markerStart = "<!-- aloud-voice:start -->"
    static let markerEnd = "<!-- aloud-voice:end -->"

    // "Agent Speak" is the product name for this capability, and it belongs in
    // every word the user or the agent reads. The CLI verbs below are the wire
    // contract, not branding, and do not move with it.
    static let summary = "Agent Speak: talk to the user through Aloud and hear their spoken answer, so you can ask a question mid-task instead of ending your turn."

    // The verbs a distributed build exposes (CLI.swift). Also the verbs Claude
    // Code's allowlist has to cover, which is why they live next to the text
    // that teaches them rather than in the installer.
    static let verbs = ["claim", "listen", "speak", "release"]

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
        # Agent Speak — talking to the user out loud

        Agent Speak is Aloud's voice channel to the person you are working for. You
        can say something through their speakers and hear their spoken answer, which
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

        **Agent Speak can be unavailable, and that is not an error.** The user can
        switch it off at any moment, or decline a single request. A refusal is a
        normal answer, not a bug: fall back to asking in text and carry on. Never
        retry in a loop.

        | refusal | what it means | what to do |
        |---|---|---|
        | `disabled` | Agent Speak is switched off in Aloud | stop asking for the rest of the session; use text |
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
        \#(command) claim   --harness \#(id) --owner-pid $PPID --name "fixing tests"
        # {"lease":"L1","ok":true}
        \#(command) speak   --harness \#(id) --lease L1 "The migration test is failing. Roll it back, or fix it forward?"
        \#(command) listen  --harness \#(id) --lease L1        # blocks, returns {"text":"..."}
        \#(command) release --harness \#(id) --lease L1        # always, even after an error
        ```

        - Pass `--harness \#(id)` on every call.
        - Pass `--name "<two words>"` saying what you are *doing* — "fixing
          tests", "release notes", "code review". The user reads it on the
          indicator, hears it in the spoken prompt ("Let fixing tests listen?"),
          and picks from it when more than one session wants the microphone.
          Two windows of the same tool cannot be told apart any other way. Two words at most, and re-send `--name` on any
          later call if what you are doing has changed.
        - Pass `--owner-pid $PPID` on `claim`, exactly as written. It is how Aloud
          tells your session apart from another session of the same tool, so the
          two queue for the microphone instead of sharing one lease — and it lets
          Aloud release your session the moment you exit, rather than leaving the
          microphone held until the lease times out. Without it you are anonymous
          and simply wait your turn.
        - `claim` returns immediately. If it comes back `{"ok":false,"reason":"queued"}`, ask
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
    func permissionEntries(for harness: AgentHarness) -> [String] {
        guard let style = harness.permissionAllowlist else { return [] }
        return AgentVoiceInstructions.permissionEntries(style: style, command: command)
    }

    var claudePermissionEntries: [String] { permissionEntries(for: .claudeCode) }
    var cursorPermissionEntries: [String] { permissionEntries(for: .cursor) }

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
    // differs, so an unchanged harness costs a read and touches nothing. A
    // harness whose config we cannot parse is skipped rather than repaired —
    // a malformed file is not ours to rewrite here, and the pane is where that
    // gets surfaced.
    // Instructions only, never permissions. A refresh runs on every launch
    // and every gate toggle, and "entry not present in settings.json" is
    // indistinguishable here from "the user revoked it" — re-adding would
    // silently re-grant hands-free shell access somebody deliberately took
    // away. Permissions are written exactly once, by the install the user
    // clicked. This also keeps a refresh from touching settings.json at all,
    // so a corrupt permissions file cannot block instruction updates.
    @discardableResult
    func refreshInstalled() -> [AgentHarness] {
        AgentHarness.allCases.filter { harness in
            guard harness.scope == .global, isInstalled(harness) else { return false }
            guard case .installed(let changed)? = try? install(harness, permissions: false)
            else { return false }
            return !changed.isEmpty
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
    func install(_ harness: AgentHarness, permissions: Bool = true) throws -> InstallResult {
        let block = AgentVoiceInstructions.markedBlock(
            AgentVoiceInstructions.body(harness: harness, command: command))

        switch harness.mechanism {
        case .snippet:
            return .snippet(ProjectSnippet(harness: harness,
                                           relativePath: harness.instructionPath,
                                           contents: block))

        case .appendedBlock:
            let url = home.appendingPathComponent(harness.instructionPath)
            let changed = try upsertBlock(block, in: url)
            return .installed(changed: changed ? [url] : [])

        case .skillFile:
            // Order matters for the harnesses with an allowlist. The permission
            // file is the only thing here that can refuse, so parse it before
            // writing anything — a failure must not leave a half-installed
            // skill behind.
            let allowlist = permissions ? allowlistURL(for: harness) : nil
            var updated: Data?
            if let allowlist {
                updated = try allowlistJSON(at: allowlist, for: harness, addingEntries: true)
            }

            var changed: [URL] = []
            let skill = home.appendingPathComponent(harness.instructionPath)
            let file = AgentVoiceInstructions.skillFile(harness: harness, command: command)
            if try writeIfDifferent(file, to: skill) { changed.append(skill) }
            if let data = updated, let allowlist {
                try write(data, to: allowlist)
                changed.append(allowlist)
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
        switch harness.mechanism {
        case .snippet:
            return  // nothing of ours is on disk to remove

        case .appendedBlock:
            try removeBlock(from: home.appendingPathComponent(harness.instructionPath))

        case .skillFile:
            try removeSkillDirectory(at: home.appendingPathComponent(harness.instructionPath))
            // The skill file goes first and unconditionally, so a harness with
            // no allowlist is finished here and the ones that have an allowlist
            // still lose their skill even if the settings step throws.
            guard let allowlist = allowlistURL(for: harness) else { return }
            // A malformed config on the way out is still not ours to rewrite —
            // surface it so the pane can say the allowlist is stale.
            if let data = try allowlistJSON(at: allowlist, for: harness, addingEntries: false) {
                try write(data, to: allowlist)
            }
            removeBackup(of: allowlist)
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
    private func allowlistJSON(at url: URL,
                               for harness: AgentHarness,
                               addingEntries adding: Bool) throws -> Data? {
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

        var changed = false
        if adding {
            let present = Set(allow.compactMap { $0 as? String })
            for entry in permissionEntries(for: harness) where !present.contains(entry) {
                allow.append(entry)
                changed = true
            }
        } else {
            let before = allow.count
            allow.removeAll { element in
                guard let entry = element as? String else { return false }
                return AgentVoiceInstructions.isPermissionEntry(entry, style: style)
            }
            changed = allow.count != before
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
    private func upsertBlock(_ block: String, in url: URL) throws -> Bool {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated: String
        if existing.contains(AgentVoiceInstructions.markerStart) {
            // Strip whatever we wrote before, then write one block. If the
            // strip could not run — a damaged or orphaned marker — appending
            // would stack a second block on top, and since a refresh runs
            // every launch the file would grow without bound. Refuse instead;
            // the pane surfaces it, and `refreshInstalled` skips it quietly.
            guard let stripped = removingBlock(from: existing) else {
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

    private func removeBlock(from url: URL) throws {
        guard let existing = try? String(contentsOf: url, encoding: .utf8),
              existing.contains(AgentVoiceInstructions.markerStart) else { return }
        guard let stripped = removingBlock(from: existing) else {
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
    private func removingBlock(from text: String) -> String? {
        func trimmed(_ line: String) -> String { line.trimmingCharacters(in: .whitespaces) }
        var lines = text.components(separatedBy: "\n")
        while let start = lines.firstIndex(where: { trimmed($0) == AgentVoiceInstructions.markerStart }) {
            guard let end = lines[start...].firstIndex(where: { trimmed($0) == AgentVoiceInstructions.markerEnd })
            else { return nil }
            guard !lines[(start + 1)..<end].contains(where: { trimmed($0) == AgentVoiceInstructions.markerStart })
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
