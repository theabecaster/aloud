import XCTest
@testable import Aloud

// Install writes into config files that belong to other tools — a user's
// `~/.claude/settings.json` is the only thing standing between them and a
// Claude Code that will not start. Every test here exists because the
// corresponding mistake is silent when it happens and expensive when it is
// found: a second install that duplicates a section, an uninstall that takes a
// neighbour's text with it, a JSON writer that flattens a file it did not
// understand, or a per-project harness quietly writing into somebody's repo.
//
// Everything runs against an injected home directory. A test that touched the
// developer's real `~` would be modifying the machine it runs on.
final class HarnessInstallerTests: XCTestCase {
    private var home: URL!
    // Its own suite, never `.standard`. The installer remembers things across
    // launches — which harnesses the user removed, which permission entries
    // they have been offered — and those memories change what a later install
    // writes. Sharing `.standard` would make the outcome depend on what ran
    // before, in this process and in every previous run on the developer's own
    // machine.
    //
    // One fixed name for the whole class, wiped on the way *in*, rather than a
    // fresh UUID per test: `removePersistentDomain` empties the domain but
    // leaves the plist on disk, and cfprefsd rewrites it asynchronously after
    // tearDown — so a per-test name loses that race and drops a file in
    // ~/Library/Preferences every single run. Thousands had piled up. A stable
    // name still isolates (the domain is emptied before each test) and can
    // leave at most one file, which `forgetTestDefaults` clears up as far as a
    // test process can — see the limits set out on that method.
    private static let suiteName = "aloud-harness-tests"
    private var defaults: UserDefaults!
    private var fm: FileManager { .default }

    override func setUpWithError() throws {
        home = fm.temporaryDirectory
            .appendingPathComponent("aloud-harness-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        try? fm.removeItem(at: home)
        forgetTestDefaults(Self.suiteName)
    }

    // Every installer a test builds goes through here, so none of them can
    // quietly pick up `.standard`.
    private func installer(command: String, home: URL? = nil) -> HarnessInstaller {
        HarnessInstaller(home: home ?? self.home, command: command, defaults: defaults)
    }

    // Pinned rather than defaulted: the real default is the running binary's
    // own path, which under `swift test` is the test runner. Fixing it here
    // keeps the expectations readable and still exercises the absolute-path
    // form the app actually installs.
    static let command = "/Applications/Aloud.app/Contents/MacOS/Aloud"

    private func installer() -> HarnessInstaller {
        installer(command: Self.command)
    }

    private func makeDir(_ relative: String) throws {
        try fm.createDirectory(at: home.appendingPathComponent(relative, isDirectory: true),
                               withIntermediateDirectories: true)
    }

    // Detection only asks "does this path exist", so a marker could be faked
    // with a directory either way. It is created as whatever the real tool
    // writes — `~/.openclaw/openclaw.json` is a file, `~/.pi/agent` is a
    // directory — because a fixture that does not look like the real thing is a
    // test agreeing with itself rather than with the machine.
    private func makeMarker(_ relative: String, under root: URL? = nil) throws {
        let url = (root ?? home).appendingPathComponent(relative)
        let name = url.lastPathComponent
        let isFile = name.dropFirst().contains(".")
        try fm.createDirectory(at: isFile ? url.deletingLastPathComponent() : url,
                               withIntermediateDirectories: true)
        if isFile { try "".write(to: url, atomically: true, encoding: .utf8) }
    }

    private func write(_ text: String, to relative: String) throws {
        let url = home.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ relative: String) -> String? {
        try? String(contentsOf: home.appendingPathComponent(relative), encoding: .utf8)
    }

    private func settingsJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func allowList() throws -> [String] {
        let permissions = try XCTUnwrap(settingsJSON()["permissions"] as? [String: Any])
        return try XCTUnwrap(permissions["allow"] as? [String])
    }

    // Cursor CLI keeps its own allowlist in its own file, in its own dialect.
    private static let cursorConfigPath = ".cursor/cli-config.json"

    private func cursorConfigJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: home.appendingPathComponent(Self.cursorConfigPath))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func cursorAllowList() throws -> [String] {
        let permissions = try XCTUnwrap(cursorConfigJSON()["permissions"] as? [String: Any])
        return try XCTUnwrap(permissions["allow"] as? [String])
    }

    // The real file on this Mac, reproduced so the fixture is the format we
    // actually have to survive rather than the format we imagined: version and
    // editor keys we must not disturb, and an allow list already carrying a
    // `Shell(...)` entry — not Claude Code's `Bash(...)`.
    private static let realCursorConfig = """
    {
      "version": 1,
      "editor": {
        "vimMode": false
      },
      "hasChangedDefaultModel": false,
      "permissions": {
        "allow": [
          "Shell(ls)"
        ],
        "deny": []
      }
    }
    """

    // MARK: - detection

    // Detection is what the Settings pane draws its rows from, so it must read
    // the injected root and nothing else. If this ever consulted the real home,
    // the test machine's own harnesses would make it pass for the wrong reason.
    func testDetectionSeesOnlyWhatIsUnderTheInjectedHome() throws {
        XCTAssertEqual(installer().detect(), [], "an empty home has no harnesses")

        try makeDir(".claude")
        try makeDir(".codex")
        let found = installer().detect().map(\.harness)
        XCTAssertEqual(found, [.claudeCode, .codex])
    }

    // Each harness keeps state in more than one place depending on version and
    // whether it is the editor or the CLI, so any one marker is enough.
    func testAlternateMarkerPathsAlsoCount() throws {
        try makeDir("Library/Application Support/Cursor")
        try makeDir(".config/github-copilot")
        let found = Set(installer().detect().map(\.harness))
        XCTAssertEqual(found, [.cursor, .copilot])
    }

    func testDetectionReportsScopeAndInstalledState() throws {
        try makeDir(".claude")
        try makeDir(".cursor")

        let before = installer().detect()
        XCTAssertEqual(before.first(where: { $0.harness == .claudeCode })?.isInstalled, false)
        XCTAssertEqual(before.first(where: { $0.harness == .cursor })?.scope, .global)

        _ = try installer().install(.claudeCode)
        let after = installer().detect()
        XCTAssertEqual(after.first(where: { $0.harness == .claudeCode })?.isInstalled, true)
        // Cursor is per project and we never wrote anything, so claiming it is
        // installed would be a lie the pane would repeat to the user.
        XCTAssertEqual(after.first(where: { $0.harness == .cursor })?.isInstalled, false)
    }

    // MARK: - Claude Code

    func testClaudeInstallWritesSkillAndAllowlist() throws {
        let result = try installer().install(.claudeCode)
        guard case .installed(let changed) = result else { return XCTFail("expected a real install") }
        XCTAssertEqual(changed.count, 3,
                       "the skill file, settings.json, and the note in ~/.claude/CLAUDE.md")

        let skill = try XCTUnwrap(read(".claude/skills/aloud-agent-speak/SKILL.md"))
        XCTAssertTrue(skill.hasPrefix("---"), "Claude Code needs the skill frontmatter")
        XCTAssertTrue(skill.contains("name: aloud-agent-speak"))
        XCTAssertTrue(skill.contains(AgentVoiceInstructions.markerStart))
        XCTAssertTrue(skill.contains("--harness claude-code"), "the harness id is baked in, not left to the agent")

        XCTAssertEqual(try allowList(), installer().claudePermissionEntries)
        XCTAssertTrue(installer().isInstalled(.claudeCode))
    }

    // The first `listen` stopping for a Bash permission prompt would break a
    // feature whose entire point is not touching the keyboard.
    func testAllowlistCoversEveryProdVerb() throws {
        _ = try installer().install(.claudeCode)
        let allow = try allowList()
        for verb in ["claim", "listen", "speak", "release"] {
            XCTAssertTrue(allow.contains("Bash(\(Self.command) \(verb):*)"),
                          "missing an allowlist entry for \(verb)")
        }
    }

    // Running the wizard twice is the normal case — the user reopens Settings
    // and presses the button again. It must be a no-op down to the byte, not
    // merely "equivalent".
    func testDoubleInstallChangesNothing() throws {
        _ = try installer().install(.claudeCode)
        let skillBefore = try XCTUnwrap(read(".claude/skills/aloud-agent-speak/SKILL.md"))
        let settingsBefore = try XCTUnwrap(read(".claude/settings.json"))

        let second = try installer().install(.claudeCode)
        guard case .installed(let changed) = second else { return XCTFail("expected an install result") }
        XCTAssertEqual(changed, [], "a repeat install must report that it wrote nothing")
        XCTAssertEqual(read(".claude/skills/aloud-agent-speak/SKILL.md"), skillBefore)
        XCTAssertEqual(read(".claude/settings.json"), settingsBefore)
    }

    // What agents are told has to travel with the app.
    //
    // `isInstalled` answers on our marker, not on what it contains — right for
    // "did the user opt in", wrong for "is this current". So an update that
    // changed the instructions left every harness installed before it running
    // the old text, reported as "Installed" and looking healthy, while telling
    // agents to call the CLI in a form that had moved on.
    func testAnOutdatedSkillIsBroughtUpToDate() throws {
        _ = try installer().install(.claudeCode)
        let current = try XCTUnwrap(read(".claude/skills/aloud-agent-speak/SKILL.md"))

        // An older Aloud's block: our markers, somebody else's body.
        let stale = current.replacingOccurrences(of: "--harness claude-code",
                                                 with: "--harness claude-code --legacy-flag")
        XCTAssertNotEqual(stale, current)
        try write(stale, to: ".claude/skills/aloud-agent-speak/SKILL.md")
        XCTAssertTrue(installer().isInstalled(.claudeCode),
                      "a stale block still reads as installed — that is the trap")

        XCTAssertEqual(installer().refreshInstalled(), [.claudeCode])
        XCTAssertEqual(read(".claude/skills/aloud-agent-speak/SKILL.md"), current,
                       "the instructions must be brought back to what this build says")
    }

    // …and a harness that is already current is not rewritten, so launching
    // the app does not churn files or their modification dates.
    func testRefreshingAnUpToDateInstallWritesNothing() throws {
        _ = try installer().install(.claudeCode)
        XCTAssertEqual(installer().refreshInstalled(), [])
    }

    // The bundle moved after install: the skill's path is refreshed, and the
    // allowlist entries have to follow it or the first `listen` prompts.
    func testRefreshMigratesAllowlistEntriesWhenTheBundleMoves() throws {
        let old = "/Applications/Aloud.app/Contents/MacOS/Aloud"
        let new = "/opt/tools/Aloud.app/Contents/MacOS/Aloud"
        _ = try installer(command: old).install(.claudeCode)
        XCTAssertTrue(try allowList().contains { $0.contains(old) })

        let moved = installer(command: new)
        XCTAssertEqual(moved.refreshInstalled(), [.claudeCode])
        let after = try allowList()
        XCTAssertTrue(after.contains { $0.contains(new) }, "entries must name the new path")
        XCTAssertFalse(after.contains { $0.contains(old) }, "the stale-path entries must be gone")
        XCTAssertEqual(after.filter { AgentVoiceInstructions.isPermissionEntry($0, style: .claudeSettings) }.count,
                       AgentVoiceInstructions.verbs.count, "no duplicates, no drops")
    }

    // A refresh must never re-grant an entry the user deliberately removed —
    // the reason permissions are otherwise written only on the explicit
    // install. Removing one entry (leaving the rest at the current path) is a
    // revocation, not a move, so the refresh leaves it removed.
    func testRefreshDoesNotReAddARevokedAllowlistEntry() throws {
        _ = try installer().install(.claudeCode)
        var allow = try allowList()
        let removed = allow.removeLast()
        XCTAssertTrue(AgentVoiceInstructions.isPermissionEntry(removed, style: .claudeSettings))
        try writeAllow(allow)

        XCTAssertEqual(installer().refreshInstalled(), [])
        XCTAssertFalse(try allowList().contains(removed), "a revoked entry stays revoked")
    }

    // Partial revoke AND a move at once: the migration follows the surviving
    // verbs to the new path and must not resurrect the one the user deleted.
    func testMigrationCarriesOnlyTheVerbsTheUserStillHas() throws {
        let old = "/Applications/Aloud.app/Contents/MacOS/Aloud"
        let new = "/opt/tools/Aloud.app/Contents/MacOS/Aloud"
        _ = try installer(command: old).install(.claudeCode)
        var allow = try allowList()
        // Drop the `speak` grant, leaving three at the old path.
        allow.removeAll { $0.contains("speak") && AgentVoiceInstructions.isPermissionEntry($0, style: .claudeSettings) }
        try writeAllow(allow)

        XCTAssertEqual(installer(command: new).refreshInstalled(), [.claudeCode])
        let after = try allowList().filter { AgentVoiceInstructions.isPermissionEntry($0, style: .claudeSettings) }
        // The three survivors move, and `ask` arrives beside them — a verb this
        // build ships that the install being migrated never offered, so there
        // is no choice of the user's to overrule. The one they *did* make is
        // the point of the test and is still honoured.
        XCTAssertFalse(after.contains { $0.contains("speak") }, "the revoked verb is not resurrected by the move")
        XCTAssertTrue(after.contains { $0.contains(" ask:") }, "a newly shipped verb is granted, not withheld")
        XCTAssertEqual(after.count, AgentVoiceInstructions.verbs.count - 1,
                       "everything this build ships except the one they deleted")
        XCTAssertTrue(after.allSatisfy { $0.contains(new) }, "everything ends up at the new path")
    }

    // The instructions and the binary have to agree about what the binary
    // answers to. They disagreed once, and the way it failed is the reason this
    // is a test rather than a comment: `ask` shipped in the skill file and in
    // every allowlist, and the argument router did not know the word. Because
    // an unrecognised argument must stay launchable — `open -a Aloud` depends
    // on it — the call did not fail. It launched the app, found it already
    // running, and exited 0 with no output at all.
    func testEveryVerbTheInstructionsTeachIsOneTheBinaryAnswersTo() {
        for verb in AgentVoiceInstructions.verbs {
            XCTAssertNotNil(BridgeOperation(rawValue: verb),
                            "the installed skill tells agents to run `\(verb)`, which nothing routes")
        }
        // The other direction, which is the one that shipped broken. A loop over
        // `verbs` cannot notice a verb *missing* from `verbs`, and `verbs` is
        // what the allowlist entries are generated from: `status` fell out of it
        // once, so the first `status` an agent ran stopped for a permission
        // prompt — in a feature whose whole premise is that nobody is watching.
        XCTAssertEqual(Set(AgentVoiceInstructions.verbs),
                       Set(BridgeOperation.allCases.map(\.rawValue)),
                       "a verb the bridge answers to but the instructions never teach "
                       + "gets no allowlist entry, and stops on turn one")
    }

    // The turn-one trap, and the reason `offeredVerbs` exists.
    //
    // Everyone who already has Agent Speak was installed by a build that shipped
    // four verbs. This one ships five and its refresh rewrites their skill file
    // to teach the new one — so unless the grant goes with it, the very first
    // `ask` stops for a permission prompt, in a feature whose whole premise is
    // that the user is not at the keyboard. The refresh is the only pass that
    // ever runs on those machines (`installAllDetected` skips them: they are
    // already installed), so it has to be the pass that does it.
    func testARefreshGrantsAVerbThisBuildAddedSinceTheLastOne() throws {
        _ = try installer().install(.claudeCode)
        // Wind the machine back to a pre-`ask` install: the four verbs of the
        // day in settings.json, and no memory of `ask` ever being offered.
        try writeAllow(try allowList().filter { !$0.contains(" ask:") })
        defaults.removeObject(forKey: "agentOfferedVerbs")
        XCTAssertFalse(try allowList().contains { $0.contains(" ask:") })

        XCTAssertEqual(installer().refreshInstalled(), [.claudeCode])

        let after = try allowList().filter { AgentVoiceInstructions.isPermissionEntry($0, style: .claudeSettings) }
        XCTAssertEqual(after.count, AgentVoiceInstructions.verbs.count,
                       "the new verb joins the four that were already there")
        XCTAssertTrue(after.contains { $0.contains(" ask:") })
        let skill = try XCTUnwrap(read(".claude/skills/aloud-agent-speak/SKILL.md"))
        XCTAssertTrue(skill.contains("ask --harness"),
                      "and the skill that teaches it went out in the same pass")
    }

    // The other half of that rule, and the one it could easily break: once a
    // verb has been offered, a refresh may never hand it back. Otherwise
    // "grant what is new" quietly becomes "grant everything, every launch",
    // and deleting a permission buys exactly one session of peace.
    func testAVerbTheUserDeletesStaysDeletedOnceItHasBeenOffered() throws {
        _ = try installer().install(.claudeCode)
        try writeAllow(try allowList().filter { !$0.contains(" ask:") })

        XCTAssertEqual(installer().refreshInstalled(), [],
                       "nothing to do: the entry is missing because they removed it")
        XCTAssertFalse(try allowList().contains { $0.contains(" ask:") },
                       "a revoked verb is not resurrected by the new-verb path")
    }

    // A refresh must update the instructions even when the permissions file is
    // corrupt — the instruction update is the point of the refresh, and a
    // broken settings.json is not allowed to hold it hostage.
    func testRefreshUpdatesInstructionsEvenWhenSettingsJSONIsCorrupt() throws {
        _ = try installer(command: "/Applications/Aloud.app/Contents/MacOS/Aloud").install(.claudeCode)
        try write("{ this is not json", to: ".claude/settings.json")
        let new = "/opt/tools/Aloud.app/Contents/MacOS/Aloud"
        _ = installer(command: new).refreshInstalled()
        let skill = try XCTUnwrap(read(".claude/skills/aloud-agent-speak/SKILL.md"))
        XCTAssertTrue(skill.contains(new), "the skill followed the new path despite the broken settings file")
        XCTAssertEqual(read(".claude/settings.json"), "{ this is not json",
                       "the corrupt file is left exactly as it was")
    }

    private func writeAllow(_ entries: [String]) throws {
        var root = try settingsJSON()
        var permissions = (root["permissions"] as? [String: Any]) ?? [:]
        permissions["allow"] = entries
        root["permissions"] = permissions
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        try data.write(to: home.appendingPathComponent(".claude/settings.json"))
    }

    // A harness the user never installed is not installed by a refresh. The
    // refresh keeps opt-ins current; it does not create them.
    func testRefreshDoesNotInstallIntoHarnessesTheUserNeverChose() throws {
        try makeMarker(".codex")
        XCTAssertEqual(installer().refreshInstalled(), [])
        XCTAssertFalse(installer().isInstalled(.codex))
    }

    // Uninstall removes every entry of ours and leaves the rest of the user's
    // settings — including their other permissions — exactly as they were.
    func testClaudeUninstallLeavesTheRestOfSettingsAlone() throws {
        try write("""
        {
          "model": "opus",
          "permissions": {
            "allow": ["Bash(git status:*)", "Read(//tmp/**)"],
            "deny": ["Bash(rm:*)"]
          }
        }
        """, to: ".claude/settings.json")

        _ = try installer().install(.claudeCode)
        // Derived rather than written out: the count is "theirs plus ours", and
        // a literal here only ever means editing this line every time a verb
        // ships. What the test is actually about is the two below surviving.
        XCTAssertEqual(try allowList().count, 2 + AgentVoiceInstructions.verbs.count)

        try installer().uninstall(.claudeCode)

        XCTAssertEqual(try allowList(), ["Bash(git status:*)", "Read(//tmp/**)"])
        let root = try settingsJSON()
        XCTAssertEqual(root["model"] as? String, "opus", "untouched keys must survive the round trip")
        let permissions = try XCTUnwrap(root["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["deny"] as? [String], ["Bash(rm:*)"])

        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".claude/skills/aloud-agent-speak/SKILL.md").path))
        XCTAssertFalse(installer().isInstalled(.claudeCode))
    }

    // A settings.json we cannot parse is the one file we must never rewrite.
    // Refusing has to happen before anything else is written, or a failed
    // install leaves a skill file pointing at a CLI the harness will prompt for.
    func testMalformedSettingsIsRefusedNotClobbered() throws {
        let broken = "{ \"permissions\": { \"allow\": [ \"Bash(git:*)\",, }"
        try write(broken, to: ".claude/settings.json")

        XCTAssertThrowsError(try installer().install(.claudeCode)) { error in
            guard case .unreadableSettings(_, let snippet)? = error as? HarnessInstallError else {
                return XCTFail("expected an unreadableSettings refusal, got \(error)")
            }
            // Refusing is only half of it: the user still needs to be able to
            // fix it by hand, so the failure carries the text to paste.
            XCTAssertTrue(snippet.contains("Bash(\(Self.command) listen:*)"),
                          "the text to paste has to be the text that would have been written")
        }

        XCTAssertEqual(read(".claude/settings.json"), broken, "the broken file must be byte-identical")
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".claude/skills/aloud-agent-speak/SKILL.md").path),
                       "nothing may be written once the install is going to fail")
    }

    // A settings.json that exists but will not open — a permission, an ACL, a
    // file somebody chmod'd while debugging — is NOT the same thing as no
    // settings.json, and it is the more expensive of the two to confuse. The
    // write below is atomic and replaces the whole file, so treating an
    // unreadable one as absent would truncate a user's entire Claude Code
    // configuration down to four permission entries. This guard is the only
    // thing standing between them and that, and until now nothing exercised it:
    // every test reached `unreadableSettings` through unparseable JSON, which
    // is the branch two lines further down.
    func testASettingsFileWeCannotOpenIsRefusedRatherThanReplaced() throws {
        let original = "{\"model\":\"opus\",\"permissions\":{\"allow\":[\"Bash(git status:*)\"]}}"
        try write(original, to: ".claude/settings.json")
        let settings = home.appendingPathComponent(".claude/settings.json")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: settings.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.path) }
        try XCTSkipIf(fm.isReadableFile(atPath: settings.path),
                      "this user can read through a chmod 000, so there is nothing to refuse")

        XCTAssertThrowsError(try installer().install(.claudeCode)) { error in
            guard case .unreadableSettings(let path, let snippet)? = error as? HarnessInstallError else {
                return XCTFail("expected an unreadableSettings refusal, got \(error)")
            }
            XCTAssertTrue(path.hasSuffix(".claude/settings.json"))
            // Refusing is only half of it: the user still has to be able to
            // finish the job by hand.
            XCTAssertTrue(snippet.contains("Bash(\(Self.command) listen:*)"))
        }

        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.path)
        XCTAssertEqual(read(".claude/settings.json"), original,
                       "the file we could not read is the file we do not write")
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".claude/skills/aloud-agent-speak/SKILL.md").path),
                       "nothing may be written once the install is going to fail")
    }

    // A block of ours whose markers do not pair up — a hand edit, an
    // interrupted write. We cannot tell which lines are ours, so we refuse both
    // ways: appending would stack a second block on top (and a refresh runs
    // every launch, so the file would grow without bound), and stripping would
    // be guessing at somebody's own text.
    func testAnInstructionFileWithAnOrphanedMarkerIsRefusedInBothDirections() throws {
        let damaged = """
        # My instructions

        Always use tabs.

        \(AgentVoiceInstructions.markerStart)
        half a block, and no end marker

        """
        try write(damaged, to: ".codex/AGENTS.md")

        XCTAssertThrowsError(try installer().install(.codex)) { error in
            guard case .damagedBlock(let path)? = error as? HarnessInstallError else {
                return XCTFail("expected a damagedBlock refusal, got \(error)")
            }
            XCTAssertTrue(path.hasSuffix(".codex/AGENTS.md"))
        }
        XCTAssertEqual(read(".codex/AGENTS.md"), damaged, "the damaged file must be byte-identical")

        // The same refusal on the way out. An uninstall that guessed here would
        // take the user's own instructions with it, which is the one loss they
        // cannot undo from the Trash.
        XCTAssertThrowsError(try installer().uninstall(.codex))
        XCTAssertEqual(read(".codex/AGENTS.md"), damaged)
    }

    // A write that cannot land has to be reported: the Settings pane says what
    // went wrong, and a silently swallowed failure would leave a row reading
    // "Installed" against a file that was never written.
    func testAWriteThatCannotLandIsReportedRatherThanSwallowed() throws {
        // Something in the way that is not a file we can replace.
        try fm.createDirectory(at: home.appendingPathComponent(".codex/AGENTS.md"),
                               withIntermediateDirectories: true)

        XCTAssertThrowsError(try installer().install(.codex)) { error in
            guard case .writeFailed(let path, let message)? = error as? HarnessInstallError else {
                return XCTFail("expected a writeFailed refusal, got \(error)")
            }
            XCTAssertTrue(path.hasSuffix(".codex/AGENTS.md"))
            XCTAssertFalse(message.isEmpty, "the pane has to be able to say what happened")
        }
        XCTAssertFalse(installer().isInstalled(.codex))
    }

    // `permissions.allow` holding something that isn't a list is the same class
    // of problem as unparseable JSON: we do not understand the file, so we do
    // not get to write it.
    func testSettingsWithAnUnexpectedShapeIsAlsoRefused() throws {
        let odd = "{\"permissions\": {\"allow\": \"everything\"}}"
        try write(odd, to: ".claude/settings.json")
        XCTAssertThrowsError(try installer().install(.claudeCode))
        XCTAssertEqual(read(".claude/settings.json"), odd)
    }

    // Somebody else's aloud-agent-speak skill is not ours to delete.
    func testUninstallSpareAForeignSkillOfTheSameName() throws {
        try write("# my own notes about aloud\n", to: ".claude/skills/aloud-agent-speak/SKILL.md")
        try installer().uninstall(.claudeCode)
        XCTAssertEqual(read(".claude/skills/aloud-agent-speak/SKILL.md"), "# my own notes about aloud\n")
    }

    // The file is not ours, so it gets copied before it is changed.
    func testExistingSettingsAreBackedUpBeforeBeingModified() throws {
        let original = "{\"model\":\"opus\"}"
        try write(original, to: ".claude/settings.json")
        _ = try installer().install(.claudeCode)
        XCTAssertEqual(read(".claude/settings.json.aloud-backup"), original)
    }

    // MARK: - Codex

    func testCodexAppendPreservesSurroundingContentOnBothSides() throws {
        try write("# My instructions\n\nAlways use tabs.\n", to: ".codex/AGENTS.md")

        _ = try installer().install(.codex)
        let withBlock = try XCTUnwrap(read(".codex/AGENTS.md"))
        XCTAssertTrue(withBlock.hasPrefix("# My instructions\n\nAlways use tabs.\n"))
        XCTAssertTrue(withBlock.contains("--harness codex"))
        XCTAssertTrue(installer().isInstalled(.codex))

        // Now add text after our block, the way a user editing the file would.
        try write(withBlock + "\nAnd never commit to main.\n", to: ".codex/AGENTS.md")

        try installer().uninstall(.codex)
        XCTAssertEqual(read(".codex/AGENTS.md"),
                       "# My instructions\n\nAlways use tabs.\n\nAnd never commit to main.\n",
                       "uninstall must take our section and the blank line we added, and nothing else")
        XCTAssertFalse(installer().isInstalled(.codex))
    }

    func testCodexDoubleInstallDoesNotDuplicateTheSection() throws {
        _ = try installer().install(.codex)
        let first = try XCTUnwrap(read(".codex/AGENTS.md"))

        let second = try installer().install(.codex)
        guard case .installed(let changed) = second else { return XCTFail("expected an install result") }
        XCTAssertEqual(changed, [])
        XCTAssertEqual(read(".codex/AGENTS.md"), first)

        let occurrences = first.components(separatedBy: AgentVoiceInstructions.markerStart).count - 1
        XCTAssertEqual(occurrences, 1)
    }

    // A stale block from an older Aloud must be replaced in place rather than
    // stacked on top of, or the agent reads two sets of instructions.
    func testCodexReinstallReplacesAnOlderBlock() throws {
        let stale = """
        Keep me.

        \(AgentVoiceInstructions.markerStart)
        # ancient instructions
        \(AgentVoiceInstructions.markerEnd)
        """
        try write(stale + "\n", to: ".codex/AGENTS.md")

        _ = try installer().install(.codex)
        let updated = try XCTUnwrap(read(".codex/AGENTS.md"))
        XCTAssertFalse(updated.contains("# ancient instructions"))
        XCTAssertTrue(updated.hasPrefix("Keep me.\n"))
        XCTAssertEqual(updated.components(separatedBy: AgentVoiceInstructions.markerStart).count - 1, 1)
    }

    // We created the file, so removing our section should not leave an empty
    // AGENTS.md behind for the harness to load.
    func testUninstallingRemovesAFileThatHeldNothingElse() throws {
        _ = try installer().install(.codex)
        try installer().uninstall(.codex)
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".codex/AGENTS.md").path))
    }

    func testUninstallingSomethingNeverInstalledIsHarmless() throws {
        XCTAssertNoThrow(try installer().uninstall(.codex))
        XCTAssertNoThrow(try installer().uninstall(.claudeCode))
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path),
                       "uninstall must not conjure a settings file that was never there")
    }

    // MARK: - per-project harnesses

    // Copilot keeps its instructions inside the user's repo. Writing there
    // would mean Aloud creating files in a git working tree the user did not
    // ask us to touch, so the install hands back text instead.
    func testCopilotReturnsASnippetAndWritesNothing() throws {
        try makeDir(".config/github-copilot")

        guard case .snippet(let snippet) = try installer().install(.copilot) else {
            return XCTFail("Copilot must not write into a project")
        }
        XCTAssertEqual(snippet.harness, .copilot)
        XCTAssertEqual(snippet.relativePath, AgentHarness.copilot.instructionPath)
        XCTAssertTrue(snippet.contents.contains("--harness copilot"))
        XCTAssertTrue(snippet.contents.contains(AgentVoiceInstructions.markerStart),
                      "the snippet carries the markers so a later manual removal is still exact")

        // Nothing new on disk beyond the marker directory we made.
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: home.path).sorted(), [".config"])
        XCTAssertFalse(installer().isInstalled(.copilot))
    }

    // Cursor reads global skills from ~/.cursor/skills/<name>/SKILL.md, the
    // same layout Claude Code uses — verified against a real installed skill.
    // An earlier draft treated it as per-project on the strength of
    // .cursor/rules/*.mdc, which is a different mechanism, and made Cursor
    // users do by hand what we can do for them.
    func testCursorInstallsGloballyLikeClaudeCode() throws {
        try makeDir(".cursor")
        guard case .installed(let changed) = try installer().install(.cursor) else {
            return XCTFail("Cursor installs globally, not as a snippet")
        }
        let skill = home.appendingPathComponent(".cursor/skills/aloud-agent-speak/SKILL.md")
        let config = home.appendingPathComponent(Self.cursorConfigPath)
        // Allowlist first, skill second — so a failure writing the allowlist
        // leaves the harness not-installed and cleanly retryable rather than
        // skill-present-permission-absent, which looks installed and prompts.
        XCTAssertEqual(changed, [config, skill],
                       "Cursor takes both halves: the allowlist that keeps the first `listen` from prompting, then the skill")
        XCTAssertTrue(fm.fileExists(atPath: skill.path))
        XCTAssertTrue(installer().isInstalled(.cursor))

        let text = try String(contentsOf: skill, encoding: .utf8)
        XCTAssertTrue(text.contains("--harness cursor"))
        XCTAssertTrue(text.hasPrefix("---\n"), "skills are read from their frontmatter")

        // And it comes back out cleanly, directory and all.
        try installer().uninstall(.cursor)
        XCTAssertFalse(fm.fileExists(atPath: skill.path))
        XCTAssertFalse(fm.fileExists(atPath: skill.deletingLastPathComponent().path))
        XCTAssertFalse(installer().isInstalled(.cursor))
    }

    // MARK: - Cursor CLI's allowlist

    // Cursor's row shipped with a skill and no allowlist entry, which is the
    // turn-one permission prompt §6 warns about — the same hole that was
    // already fixed for Claude Code — in the one harness where it was easy to
    // miss because the skill install looked complete.
    func testCursorInstallWritesItsOwnAllowlistInItsOwnDialect() throws {
        try write(Self.realCursorConfig, to: Self.cursorConfigPath)
        _ = try installer().install(.cursor)

        let allow = try cursorAllowList()
        XCTAssertEqual(allow.first, "Shell(ls)", "the user's own entry stays, and stays first")
        for verb in AgentVoiceInstructions.verbs {
            XCTAssertTrue(allow.contains("Shell(\(Self.command):\(verb)*)"),
                          "missing a Cursor allowlist entry for \(verb)")
        }
        // Cursor's syntax is `Shell(...)`, not Claude Code's `Bash(...)`. Both
        // files carry a `permissions.allow` array, so the wrong dialect would
        // write cleanly, parse cleanly, and silently match nothing.
        XCTAssertFalse(allow.contains(where: { $0.hasPrefix("Bash(") }))

        // Keys we never look at survive the round trip.
        let root = try cursorConfigJSON()
        XCTAssertEqual(root["version"] as? Int, 1)
        XCTAssertEqual(root["hasChangedDefaultModel"] as? Bool, false)
        XCTAssertEqual((root["editor"] as? [String: Any])?["vimMode"] as? Bool, false)
        XCTAssertEqual((root["permissions"] as? [String: Any])?["deny"] as? [String], [])
    }

    // The single-source rule, for Cursor. An entry only silences the prompt if
    // it names the command line the agent was told to type — and Cursor spells
    // that differently from Claude Code, so "we already tested this" is exactly
    // the assumption that would let the two drift.
    func testEveryCursorAllowlistEntryNamesACommandTheInstructionsTeach() {
        for command in [Self.command, "aloud", "/opt/my apps/Aloud.app/Contents/MacOS/Aloud"] {
            let installer = installer(command: command)
            let body = AgentVoiceInstructions.body(harness: .cursor, command: command)
            XCTAssertEqual(installer.cursorPermissionEntries.count, AgentVoiceInstructions.verbs.count)
            for entry in installer.cursorPermissionEntries {
                let typed = AgentVoiceInstructions.permittedCommandLine(entry, style: .cursorCLIConfig)
                XCTAssertNotNil(typed, "\(entry) does not parse back to a command line")
                XCTAssertTrue(body.contains(typed ?? "\u{0}"),
                              "the allowlist expects `\(typed ?? "")`, which the instructions never tell the agent to type")
            }
        }
    }

    // Same invariant held against the bytes on disk, so a future change to the
    // skill wrapper — frontmatter, escaping, indentation — is caught too.
    func testTheInstalledCursorSkillAndItsAllowlistAgree() throws {
        _ = try installer().install(.cursor)
        let skill = try XCTUnwrap(read(".cursor/skills/aloud-agent-speak/SKILL.md"))
        let ours = try cursorAllowList().filter {
            AgentVoiceInstructions.isPermissionEntry($0, style: .cursorCLIConfig)
        }
        XCTAssertEqual(ours.count, AgentVoiceInstructions.verbs.count)
        for entry in ours {
            let typed = try XCTUnwrap(AgentVoiceInstructions.permittedCommandLine(entry, style: .cursorCLIConfig))
            XCTAssertTrue(skill.contains(typed), "cli-config.json allows `\(typed)` but the skill never mentions it")
        }
    }

    // A bundle kept somewhere with a space in its path is ordinary, and the two
    // files have to agree on the quoting or the entry matches nothing.
    func testCursorQuotesASpacedPathTheSameWayInBothPlaces() throws {
        let spaced = "/Users/someone/My Apps/Aloud.app/Contents/MacOS/Aloud"
        let installer = installer(command: spaced)
        _ = try installer.install(.cursor)

        let skill = try XCTUnwrap(read(".cursor/skills/aloud-agent-speak/SKILL.md"))
        XCTAssertTrue(skill.contains("'\(spaced)' listen"), "the sample commands must be runnable as written")
        XCTAssertTrue(try cursorAllowList().contains("Shell('\(spaced)':listen*)"))
    }

    func testCursorDoubleInstallChangesNothing() throws {
        try write(Self.realCursorConfig, to: Self.cursorConfigPath)
        _ = try installer().install(.cursor)
        let configBefore = try XCTUnwrap(read(Self.cursorConfigPath))

        guard case .installed(let changed) = try installer().install(.cursor) else {
            return XCTFail("expected an install result")
        }
        XCTAssertEqual(changed, [], "a repeat install must report that it wrote nothing")
        XCTAssertEqual(read(Self.cursorConfigPath), configBefore)
    }

    // Removal takes exactly our four and nothing that merely looks like them:
    // a differently named tool, a verb we do not ship, and the user's own rules.
    func testCursorUninstallRemovesOnlyOurEntries() throws {
        try write("""
        {
          "version": 1,
          "permissions": {
            "allow": [
              "Shell(ls)",
              "Shell(aloudmixer:listen*)",
              "Shell(\(Self.command):deploy*)",
              "Shell(git)"
            ],
            "deny": ["Shell(rm)"]
          }
        }
        """, to: Self.cursorConfigPath)

        _ = try installer().install(.cursor)
        XCTAssertEqual(try cursorAllowList().count, 4 + AgentVoiceInstructions.verbs.count)

        try installer().uninstall(.cursor)
        XCTAssertEqual(try cursorAllowList(),
                       ["Shell(ls)", "Shell(aloudmixer:listen*)",
                        "Shell(\(Self.command):deploy*)", "Shell(git)"])
        XCTAssertEqual((try cursorConfigJSON()["permissions"] as? [String: Any])?["deny"] as? [String],
                       ["Shell(rm)"])
        XCTAssertEqual(try cursorConfigJSON()["version"] as? Int, 1)
    }

    // Recognising an entry on the way out has to be looser than writing one, or
    // an install from a build that quoted differently, or ran from a different
    // bundle location, leaves a rule permitting a binary that no longer exists.
    func testCursorUninstallRemovesEntriesFromAnyEarlierInvocationForm() throws {
        try write("""
        {
          "permissions": {
            "allow": [
              "Shell(aloud:listen*)",
              "Shell(/Volumes/Old/Aloud.app/Contents/MacOS/Aloud:claim*)",
              "Shell('/Users/someone/My Apps/Aloud.app/Contents/MacOS/Aloud':speak*)",
              "Shell(/Applications/Aloud.app/Contents/MacOS/Aloud:release)",
              "Shell(ls)",
              "Shell(aloud)",
              "Shell(curl:*)"
            ]
          }
        }
        """, to: Self.cursorConfigPath)

        try installer().uninstall(.cursor)

        // What stays: two of the user's own rules, plus the bare
        // `Shell(aloud)` — no verb, so it grants every argument list and is not
        // a shape this app has ever written. Guessing that one is ours would be
        // us deleting a permission somebody chose.
        XCTAssertEqual(try cursorAllowList(), ["Shell(ls)", "Shell(aloud)", "Shell(curl:*)"])
    }

    // The same refusal Claude Code gets. A cli-config.json we cannot parse is
    // the file standing between the user and a working Cursor CLI, and the
    // refusal has to happen before the skill is written so a failed install
    // does not leave instructions behind that will prompt on every call.
    func testMalformedCursorConfigIsRefusedNotClobbered() throws {
        let broken = "{ \"permissions\": { \"allow\": [ \"Shell(ls)\",, }"
        try write(broken, to: Self.cursorConfigPath)

        XCTAssertThrowsError(try installer().install(.cursor)) { error in
            guard case .unreadableSettings(let path, let snippet)? = error as? HarnessInstallError else {
                return XCTFail("expected an unreadableSettings refusal, got \(error)")
            }
            XCTAssertTrue(path.hasSuffix(Self.cursorConfigPath), "the refusal has to name Cursor's file, not Claude Code's")
            // The text to paste has to be the text we would have written, in
            // Cursor's dialect.
            XCTAssertTrue(snippet.contains("Shell(\(Self.command):listen*)"))
        }

        XCTAssertEqual(read(Self.cursorConfigPath), broken, "the broken file must be byte-identical")
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".cursor/skills/aloud-agent-speak/SKILL.md").path),
                       "nothing may be written once the install is going to fail")
    }

    // The file is Cursor's, not ours, so it is copied before it is changed.
    func testCursorConfigIsBackedUpBeforeBeingModifiedAndTidiedAfter() throws {
        try write(Self.realCursorConfig, to: Self.cursorConfigPath)
        _ = try installer().install(.cursor)
        XCTAssertEqual(read(Self.cursorConfigPath + ".aloud-backup"), Self.realCursorConfig)

        try installer().uninstall(.cursor)
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(Self.cursorConfigPath + ".aloud-backup").path),
                       "once the file is back the way we found it, the backup is our litter")
    }

    // Neither harness with an allowlist may reach for the other's file. They
    // share the install branch and the `permissions.allow` shape, so crossing
    // them would write valid JSON into the wrong config and match nothing.
    func testTheTwoAllowlistHarnessesStayOutOfEachOthersConfigs() throws {
        try write("{\"model\":\"opus\"}", to: ".claude/settings.json")
        try write(Self.realCursorConfig, to: Self.cursorConfigPath)

        _ = try installer().install(.cursor)
        XCTAssertEqual(read(".claude/settings.json"), "{\"model\":\"opus\"}",
                       "installing Cursor must not touch Claude Code's settings")

        _ = try installer().install(.claudeCode)
        XCTAssertEqual(try cursorAllowList().filter { $0.hasPrefix("Bash(") }, [])
        XCTAssertEqual(try allowList().filter { $0.hasPrefix("Shell(") }, [])
    }

    // A skill of ours is deleted on uninstall; one that merely shares the name
    // is somebody else's file.
    func testCursorUninstallLeavesAForeignSkillAlone() throws {
        let skill = home.appendingPathComponent(".cursor/skills/aloud-agent-speak/SKILL.md")
        try fm.createDirectory(at: skill.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try "hand written, not ours".write(to: skill, atomically: true, encoding: .utf8)

        try installer().uninstall(.cursor)
        XCTAssertTrue(fm.fileExists(atPath: skill.path))
    }

    // MARK: - harnesses added after launch

    // OpenCode and pi both have a real skills directory, so they reuse the
    // global-skill branch untouched — which is the claim this test is here to
    // hold to. If adding a harness ever needs more than a row in the table,
    // the abstraction is wrong and this is where that shows up.
    //
    // The paths are the part worth pinning, because they are the part that
    // ships broken while looking installed:
    //  - OpenCode scans ~/.opencode for `{skill,skills}/**/SKILL.md`.
    //  - pi auto-discovers `<agentDir>/skills/**/SKILL.md`, agentDir = ~/.pi/agent.
    //    ~/.pi/skills — which does exist on real machines, written there by
    //    other tools — is pi's *per-project* layout misapplied to home, and pi
    //    never reads it.
    //
    // OpenClaw and Hermes join the same list on weaker evidence, and the list
    // is where that costs nothing: neither is installed on this Mac, so their
    // paths come from published docs and the projects' own source rather than a
    // directory listing. What these tests can still prove is everything on our
    // side of the line — that the row reuses the shared branch, writes only
    // where the table says, is idempotent, and comes back out — and that is
    // most of what goes wrong. The one thing they cannot prove is that the tool
    // reads the directory at all, which is why detection is pinned to a marker
    // only the real tool writes (below).
    private static let addedHarnesses: [(AgentHarness, String, String)] = [
        (.opencode, ".opencode", ".opencode/skills/aloud-agent-speak/SKILL.md"),
        (.pi, ".pi/agent", ".pi/agent/skills/aloud-agent-speak/SKILL.md"),
        (.openclaw, ".openclaw/openclaw.json", ".openclaw/skills/aloud-agent-speak/SKILL.md"),
        (.hermes, ".hermes/config.yaml", ".hermes/skills/aloud-agent-speak/SKILL.md"),
    ]

    func testAddedHarnessesInstallAsGlobalSkillFiles() throws {
        for (harness, marker, path) in Self.addedHarnesses {
            try makeMarker(marker)
            // A harness only gets a note where it already keeps its global
            // instructions; the installer never creates that directory (the
            // XDG rule in installGlobalNote), so a realistic install has it.
            if let note = harness.globalNotePath {
                try makeMarker((note as NSString).deletingLastPathComponent)
            }
            guard case .installed(let changed) = try installer().install(harness) else {
                return XCTFail("\(harness.id) installs globally, not as a snippet")
            }
            let skill = home.appendingPathComponent(path)
            // The note in the harness's own global instructions rides along
            // where the harness has such a file (globalNotePath); the ones
            // that don't still write the skill and nothing else.
            var expected = [skill]
            if let note = harness.globalNotePath {
                expected.append(home.appendingPathComponent(note))
            }
            XCTAssertEqual(changed, expected, "\(harness.id) wrote somewhere unexpected")

            let text = try XCTUnwrap(read(path))
            XCTAssertTrue(text.hasPrefix("---\n"), "skills are read from their frontmatter")
            XCTAssertTrue(text.contains("name: aloud-agent-speak"))
            XCTAssertTrue(text.contains(AgentVoiceInstructions.markerStart))
            XCTAssertTrue(text.contains("--harness \(harness.id)"),
                          "the harness id is baked in, not left to the agent")
            XCTAssertTrue(installer().isInstalled(harness))
        }
    }

    // pi rejects a skill whose frontmatter `name` differs from its parent
    // directory, and truncates nothing — it just refuses to load it. So the
    // one-source frontmatter has to agree with the one-source directory name,
    // and a rename of either alone is a skill that silently never appears.
    func testTheSkillNameMatchesTheDirectoryItIsWrittenInto() throws {
        for (harness, marker, path) in Self.addedHarnesses {
            try makeMarker(marker)
            _ = try installer().install(harness)
            let directory = home.appendingPathComponent(path)
                .deletingLastPathComponent().lastPathComponent
            let text = try XCTUnwrap(read(path))
            XCTAssertTrue(text.contains("name: \(directory)"),
                          "\(harness.id): frontmatter name must match the directory \(directory)")
        }
    }

    // The reopen-Settings-and-press-it-again case, for the new rows too.
    func testAddedHarnessesDoubleInstallChangesNothing() throws {
        for (harness, marker, path) in Self.addedHarnesses {
            try makeMarker(marker)
            _ = try installer().install(harness)
            let first = try XCTUnwrap(read(path))

            guard case .installed(let changed) = try installer().install(harness) else {
                return XCTFail("expected an install result")
            }
            XCTAssertEqual(changed, [], "a repeat install must report that it wrote nothing")
            XCTAssertEqual(read(path), first)
        }
    }

    func testAddedHarnessesUninstallCleanlyIncludingTheDirectory() throws {
        for (harness, marker, path) in Self.addedHarnesses {
            try makeMarker(marker)
            _ = try installer().install(harness)

            try installer().uninstall(harness)
            let skill = home.appendingPathComponent(path)
            XCTAssertFalse(fm.fileExists(atPath: skill.path))
            XCTAssertFalse(fm.fileExists(atPath: skill.deletingLastPathComponent().path),
                           "the directory we created goes with the file we wrote into it")
            XCTAssertFalse(installer().isInstalled(harness))
        }
    }

    // A skill of the same name that we did not write is somebody's own work.
    // Without the marker check, "uninstall Aloud" would delete it.
    func testAddedHarnessesUninstallLeavesAForeignSkillAlone() throws {
        for (_, _, path) in Self.addedHarnesses {
            try write("# hand written, not ours\n", to: path)
        }
        for (harness, _, path) in Self.addedHarnesses {
            try installer().uninstall(harness)
            XCTAssertEqual(read(path), "# hand written, not ours\n")
        }
    }

    // Detection drives the Settings rows, so every marker has to work on its
    // own — a user who has run OpenCode once may have only one of its three
    // directories, and no marker may be inferred from another harness's.
    func testAddedHarnessesAreDetectedFromEachOfTheirOwnMarkers() throws {
        for (harness, _, _) in Self.addedHarnesses {
            for marker in harness.detectionPaths {
                let scratch = home.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try makeMarker(marker, under: scratch)
                let found = installer(command: Self.command, home: scratch).detect().map(\.harness)
                XCTAssertEqual(found, [harness], "\(marker) should mean \(harness.id) and nothing else")
            }
        }
    }

    // pi's home marker is ~/.pi/agent, not ~/.pi, because ~/.pi is also the
    // name of pi's *per-project* config directory. A home directory that is
    // itself a checkout would otherwise show a harness that isn't installed.
    func testABarePiDirectoryIsNotEnoughToClaimPiIsInstalled() throws {
        try makeDir(".pi/skills")
        XCTAssertEqual(installer().detect(), [])
    }

    // MARK: - the rows we could not verify against a live install

    // The whole risk of adding a harness from documentation is a row that reads
    // "Installed" while the file it wrote is somewhere the tool never looks.
    // Detection is the only defence: if the marker is something only the real
    // tool creates, then being wrong about the *install* path costs a skill
    // that does nothing, while being wrong about the *marker* costs a row that
    // appears for people who have never heard of the tool.
    //
    // So these two are pinned to files the tools write themselves —
    // openclaw.json is OpenClaw's config, config.yaml and SOUL.md are Hermes'
    // settings and persona files — and the near-misses below are pinned as
    // misses.
    func testTheUnverifiedRowsNeedAMarkerOnlyTheRealToolWrites() throws {
        // ~/.agents/skills is a cross-tool convention: it exists on this
        // developer's Mac, put there by something that is not OpenClaw, and
        // OpenClaw does read it. Detecting on it would light the row up for
        // anyone who has ever installed any agent skill anywhere — the
        // ~/.pi/skills mistake with a different directory name.
        try makeDir(".agents/skills")
        XCTAssertEqual(installer().detect(), [], "a shared skills directory is not evidence of any one harness")

        // A bare state directory is not much better: empty, or left behind by
        // an uninstall, or made by hand.
        try makeDir(".openclaw")
        try makeDir(".hermes")
        XCTAssertEqual(installer().detect(), [], "an empty state directory does not mean the tool has run")

        try makeMarker(".openclaw/openclaw.json")
        try makeMarker(".hermes/SOUL.md")
        XCTAssertEqual(Set(installer().detect().map(\.harness)), [.openclaw, .hermes])
    }

    // The subtlest version of the same mistake: if a detection marker is a
    // directory our own install creates, the row lights up because we
    // installed, for everyone, whether or not the harness exists — and it looks
    // exactly like success.
    //
    // Held only against the two documentation-derived rows, and that limit is
    // the point rather than an oversight. The older rows detect on the state
    // directory they also install into (`~/.claude`, `~/.codex`, `~/.cursor`,
    // `~/.opencode`, `~/.pi/agent`), which is survivable there because the
    // install path was verified: writing into it means the tool is real. Here
    // the install path is the guess, so it is not allowed to be the evidence
    // as well.
    func testTheUnverifiedRowsCannotDetectThemselvesFromTheirOwnInstall() throws {
        for harness in [AgentHarness.openclaw, .hermes] {
            let scratch = home.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            let installer = installer(command: Self.command, home: scratch)
            _ = try installer.install(harness)
            XCTAssertTrue(installer.isInstalled(harness), "the skill really was written")
            XCTAssertEqual(installer.detect(), [],
                           "\(harness.id) detects itself from the files we wrote")
        }
    }

    // Every path we write to has to be under a directory belonging to the
    // harness it is for. A typo that put OpenClaw's skill under ~/.hermes would
    // otherwise pass every test above — both rows install, both are idempotent,
    // both uninstall — while each tool reads the other's file.
    func testEachHarnessWritesUnderItsOwnRoot() {
        let roots: [AgentHarness: String] = [
            .claudeCode: ".claude/", .codex: ".codex/", .cursor: ".cursor/",
            .copilot: ".github/", .opencode: ".opencode/", .pi: ".pi/",
            .openclaw: ".openclaw/", .hermes: ".hermes/",
        ]
        for harness in AgentHarness.allCases {
            let root = roots[harness]
            XCTAssertNotNil(root, "\(harness.id) was added without saying where it writes")
            XCTAssertTrue(harness.instructionPath.hasPrefix(root ?? "\u{0}"),
                          "\(harness.id) writes to \(harness.instructionPath), outside \(root ?? "")")
        }
    }

    // Only Claude Code has an allowlist that would otherwise stop the first
    // `listen` for a permission prompt. OpenCode's agents default to allowing
    // bash and pi has no allowlist concept at all, so writing one for them
    // would be editing a config file for no reason — and worse, this test
    // catches the version of that mistake where they reach for *Claude Code's*
    // settings.json because they share the install branch.
    func testAHarnessWithoutAnAllowlistNeverTouchesClaudeCodesSettings() throws {
        try write("{\"model\":\"opus\"}", to: ".claude/settings.json")
        for (harness, marker, _) in Self.addedHarnesses {
            try makeMarker(marker)
            _ = try installer().install(harness)
            try installer().uninstall(harness)
        }
        XCTAssertEqual(read(".claude/settings.json"), "{\"model\":\"opus\"}")
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".claude/settings.json.aloud-backup").path),
                       "not even a backup: we never opened it")
    }

    // MARK: - the instructions themselves

    // The behaviour we install is the feature. An agent that opens the
    // microphone silently, or that treats a refusal as a bug and retries, makes
    // the user turn voice off — so these points are pinned rather than trusted
    // to survive future edits of the copy.
    func testInstructionsTellTheAgentTheFiveThingsThatMatter() throws {
        let body = AgentVoiceInstructions.body(harness: .claudeCode, command: "aloud")
        // "Speak before every listen" used to be a rule here because `listen`
        // could be called on its own, and an agent that did opened the
        // microphone on a question nobody knew had been asked. `ask` makes the
        // ordering structural instead — it speaks and then listens, in one
        // call — so what is pinned now is that the body leads with it rather
        // than with the pair that can be got wrong.
        XCTAssertTrue(body.contains("ask --harness"))
        XCTAssertLessThan(try XCTUnwrap(body.range(of: "ask --harness")).lowerBound,
                          try XCTUnwrap(body.range(of: "listen --start")).lowerBound,
                          "the one-call form is what an agent should meet first")
        XCTAssertTrue(body.contains("One or two sentences, question last"))
        XCTAssertTrue(body.contains("stop telling me every time"))
        XCTAssertTrue(body.contains("`disabled`"))
        XCTAssertTrue(body.contains("`denied`"))
        // Unwrapped before matching: the copy is hard-wrapped, so a reflow that
        // moves a line break must not silently drop the assertion.
        let flowed = body.lowercased().replacingOccurrences(of: "\n", with: " ")
        XCTAssertTrue(flowed.contains("never retry in a loop") || flowed.contains("do not spin"))
        for verb in ["claim", "listen", "speak", "release"] {
            XCTAssertTrue(body.contains("\(verb) "), "the mechanics must mention `\(verb)`")
        }
    }

    // One body, N wrappers. If a harness ever grew its own copy of the text the
    // two would drift within a release.
    //
    // Normalised on `--harness <id>` rather than on the bare id, which is the
    // only place an id may appear. A bare-substring replacement was fine while
    // every id was a long word, and stopped being fine the moment a harness was
    // called `pi`: it also rewrites the middle of "stopping" and "spin".
    func testEveryHarnessGetsTheSameBody() {
        let bodies = AgentHarness.allCases.map { harness -> String in
            let body = AgentVoiceInstructions.body(harness: harness, command: "aloud")
            XCTAssertTrue(body.contains("--harness \(harness.id)"))
            return body.replacingOccurrences(of: "--harness \(harness.id)", with: "--harness <id>")
        }
        XCTAssertEqual(Set(bodies).count, 1, "the instruction text must have exactly one source")
    }

    // The flip side of the normalisation above: every id has to survive being
    // pasted into a shell as `--harness <id>`, because that is the only place
    // it is ever used and the allowlist covers no other form.
    func testEveryHarnessIdIsSafeToPassOnACommandLine() {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for harness in AgentHarness.allCases {
            XCTAssertFalse(harness.id.isEmpty)
            XCTAssertTrue(harness.id.unicodeScalars.allSatisfy(safe.contains),
                          "\(harness.id) would need quoting, which nothing here does")
        }
    }

    // A dev build must not tell agents to run the installed bundle.
    func testTheCommandIsInjectable() throws {
        let custom = installer(command: "/opt/aloud/bin/aloud")
        _ = try custom.install(.codex)
        XCTAssertTrue(try XCTUnwrap(read(".codex/AGENTS.md")).contains("/opt/aloud/bin/aloud claim"))
    }

    // MARK: - the invocation form

    // The reason this whole invariant exists. A `Bash(…)` entry only silences
    // the permission prompt if it is the literal prefix of what the agent
    // typed, and what the agent types is whatever the instructions showed it.
    // If those two are ever generated separately they will drift, and the
    // symptom is a permission prompt on turn one of a hands-free feature —
    // nothing crashes, nothing logs, the demo just stalls.
    func testEveryAllowlistEntryIsAPrefixOfWhatTheInstructionsTellTheAgentToType() throws {
        for command in [Self.command, "aloud", "/opt/my apps/Aloud.app/Contents/MacOS/Aloud"] {
            let installer = installer(command: command)
            let body = AgentVoiceInstructions.body(harness: .claudeCode, command: command)
            for entry in installer.claudePermissionEntries {
                let typed = String(entry.dropFirst("Bash(".count).dropLast(":*)".count))
                XCTAssertTrue(body.contains(typed),
                              "the allowlist expects `\(typed)`, which the instructions never tell the agent to type")
            }
            XCTAssertEqual(installer.claudePermissionEntries.count, AgentVoiceInstructions.verbs.count)
        }
    }

    // Same invariant against the bytes actually on disk, so a future wrapper
    // that rewrites the body (frontmatter, indentation, escaping) is caught too.
    func testTheInstalledSkillAndTheInstalledAllowlistAgree() throws {
        _ = try installer().install(.claudeCode)
        let skill = try XCTUnwrap(read(".claude/skills/aloud-agent-speak/SKILL.md"))
        for entry in try allowList() {
            let typed = String(entry.dropFirst("Bash(".count).dropLast(":*)".count))
            XCTAssertTrue(skill.contains(typed), "settings.json allows `\(typed)` but the skill never mentions it")
        }
    }

    // There is no `aloud` on PATH — the CLI lives inside the app bundle — so a
    // default of "aloud" would mean every install shipped instructions that
    // fail at the shell and an allowlist that matches nothing.
    func testTheDefaultCommandIsAnAbsolutePathNotABarePathLookup() {
        let fallback = HarnessInstaller.defaultCommand
        XCTAssertTrue(fallback.hasPrefix("/"), "expected an absolute path, got \(fallback)")
        XCTAssertFalse(fallback.contains("/AppTranslocation/"),
                       "a randomised Gatekeeper mount would outlive the settings.json we wrote it into")
    }

    // A bundle kept somewhere with a space in the path is ordinary. Unquoted
    // the agent's shell splits it; quoted differently in the two files the
    // allowlist stops matching — so one quoting decision, applied in both.
    func testAPathWithSpacesIsQuotedTheSameWayInBothPlaces() throws {
        let spaced = "/Users/someone/My Apps/Aloud.app/Contents/MacOS/Aloud"
        let installer = installer(command: spaced)
        _ = try installer.install(.claudeCode)

        let skill = try XCTUnwrap(read(".claude/skills/aloud-agent-speak/SKILL.md"))
        XCTAssertTrue(skill.contains("'\(spaced)' claim"), "the sample commands must be runnable as written")
        XCTAssertTrue(try allowList().contains("Bash('\(spaced)' claim:*)"))
    }

    // Uninstall has to recognise entries this build would not have written:
    // one left by an older Aloud that assumed a bare `aloud` on PATH, or by
    // this one before the user moved the bundle. An entry we fail to match is
    // one we leave behind allowing a binary that no longer exists.
    func testUninstallRemovesAllowlistEntriesFromAnyEarlierInvocationForm() throws {
        try write("""
        {
          "permissions": {
            "allow": [
              "Bash(aloud listen:*)",
              "Bash(/Volumes/Old/Aloud.app/Contents/MacOS/Aloud claim:*)",
              "Bash('/Users/someone/My Apps/Aloud.app/Contents/MacOS/Aloud' speak:*)",
              "Bash(aloudmixer listen:*)",
              "Bash(aloud deploy:*)",
              "Bash(git status:*)"
            ]
          }
        }
        """, to: ".claude/settings.json")

        try installer().uninstall(.claudeCode)

        // The last three are not ours: a differently named tool, a verb we do
        // not ship, and somebody's own rule.
        XCTAssertEqual(try allowList(),
                       ["Bash(aloudmixer listen:*)", "Bash(aloud deploy:*)", "Bash(git status:*)"])
    }

    // MARK: - the old name
    //
    // Agent Speak used to be called `aloud-voice`, and every install carried
    // that name: a skill directory, a marked block in somebody's AGENTS.md, and
    // a note in their ~/.claude/CLAUDE.md. The rename cleans all three up, once,
    // on the first launch after the update — which means this code deletes
    // directories and rewrites instruction files people have kept for years,
    // unprompted, on every launch, and nothing exercised it at all. Mutating it
    // to `if true { return }` left the whole suite green.
    //
    // Everything here runs against the injected home. A test that let this
    // loose on the real `~` would be deleting the developer's own skills.

    private static let legacySkillPath = ".claude/skills/aloud-voice/SKILL.md"

    private func legacySkillBody() -> String {
        "\(HarnessInstaller.LegacyNames.markerStart)\n# aloud-voice\nSay something.\n"
        + "\(HarnessInstaller.LegacyNames.markerEnd)\n"
    }

    private func legacyNote() -> String {
        "\(HarnessInstaller.LegacyNames.noteMarkerStart)\n"
        + "Ask the user out loud with `aloud-voice`.\n"
        + "\(HarnessInstaller.LegacyNames.noteMarkerEnd)"
    }

    // All three shapes the old name was installed in, taken out together.
    func testTheOldNamesInstallsAreAllCleanedUp() throws {
        try write(legacySkillBody(), to: Self.legacySkillPath)
        try write("# my notes\n\n\(HarnessInstaller.LegacyNames.markerStart)\n"
                  + "Old Aloud instructions.\n"
                  + "\(HarnessInstaller.LegacyNames.markerEnd)\n\n# more of mine\n",
                  to: ".codex/AGENTS.md")
        try write("# my rules\n\n\(legacyNote())\n\n# more rules\n", to: ".claude/CLAUDE.md")

        installer().removeLegacyNamedInstalls()

        XCTAssertNil(read(Self.legacySkillPath), "the old skill still teaches the old name")
        XCTAssertFalse(fm.fileExists(atPath:
            home.appendingPathComponent(".claude/skills/aloud-voice").path),
                       "and its directory is litter once the file has gone")

        let codex = try XCTUnwrap(read(".codex/AGENTS.md"))
        XCTAssertFalse(codex.contains(HarnessInstaller.LegacyNames.markerStart),
                       "the old block is duplicated beside the new one until this runs")
        XCTAssertTrue(codex.contains("# my notes"), "and the user's own text is untouched")
        XCTAssertTrue(codex.contains("# more of mine"))

        let claude = try XCTUnwrap(read(".claude/CLAUDE.md"))
        XCTAssertFalse(claude.contains("aloud-voice"), "the old note goes the same way")
        XCTAssertTrue(claude.contains("# my rules"))
        XCTAssertTrue(claude.contains("# more rules"))
    }

    // The guard that makes all of the above safe to run unasked. A directory
    // that happens to share the old name but carries none of our markers was
    // written by somebody else, and is not ours to delete.
    func testAForeignSkillOfTheOldNameSurvives() throws {
        let mine = "# aloud-voice\n\nmy own notes, nothing to do with Aloud\n"
        try write(mine, to: Self.legacySkillPath)

        installer().removeLegacyNamedInstalls()

        XCTAssertEqual(read(Self.legacySkillPath), mine,
                       "a file Aloud never wrote must survive Aloud's cleanup")
    }

    // A block whose markers do not pair up — a hand edit, an interrupted
    // write — cannot be parsed with certainty, so the file is left exactly as
    // it was rather than guessed at. Byte-identical, not merely equivalent.
    func testADamagedOldBlockLeavesTheFileAlone() throws {
        let damaged = "# my notes\n\n\(HarnessInstaller.LegacyNames.markerStart)\n"
            + "Old Aloud instructions, and the end marker never arrived.\n\n# more of mine\n"
        try write(damaged, to: ".codex/AGENTS.md")
        let before = try Data(contentsOf: home.appendingPathComponent(".codex/AGENTS.md"))

        installer().removeLegacyNamedInstalls()

        let after = try Data(contentsOf: home.appendingPathComponent(".codex/AGENTS.md"))
        XCTAssertEqual(after, before,
                       "we cannot prove which lines are ours, so we touch none of them")
    }

    // MARK: - hygiene

    // The backup exists to answer "what did this look like before Aloud touched
    // it". Once we have put the file back, it is our litter — and the copy we
    // take on the way out would be the version *with* our entries in it.
    func testUninstallTakesItsOwnBackupsWithIt() throws {
        try write("{\"model\":\"opus\"}", to: ".claude/settings.json")
        try write("# mine\n", to: ".codex/AGENTS.md")

        _ = try installer().install(.claudeCode)
        _ = try installer().install(.codex)
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent(".claude/settings.json.aloud-backup").path))
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent(".codex/AGENTS.md.aloud-backup").path))

        try installer().uninstall(.claudeCode)
        try installer().uninstall(.codex)
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".claude/settings.json.aloud-backup").path))
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".codex/AGENTS.md.aloud-backup").path))
    }

    // The exception: an uninstall that could not finish leaves the backup,
    // because at that point it is the user's only record of the original file.
    func testAFailedUninstallKeepsTheBackupItMightStillNeed() throws {
        try write("{\"model\":\"opus\"}", to: ".claude/settings.json")
        _ = try installer().install(.claudeCode)
        try write("{ not json", to: ".claude/settings.json")

        XCTAssertThrowsError(try installer().uninstall(.claudeCode))
        XCTAssertEqual(read(".claude/settings.json.aloud-backup"), "{\"model\":\"opus\"}")
    }
}
