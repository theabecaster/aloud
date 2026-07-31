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
    private var fm: FileManager { .default }

    override func setUpWithError() throws {
        home = fm.temporaryDirectory
            .appendingPathComponent("aloud-harness-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: home)
    }

    // Pinned rather than defaulted: the real default is the running binary's
    // own path, which under `swift test` is the test runner. Fixing it here
    // keeps the expectations readable and still exercises the absolute-path
    // form the app actually installs.
    static let command = "/Applications/Aloud.app/Contents/MacOS/Aloud"

    private func installer() -> HarnessInstaller {
        HarnessInstaller(home: home, command: Self.command)
    }

    private func makeDir(_ relative: String) throws {
        try fm.createDirectory(at: home.appendingPathComponent(relative, isDirectory: true),
                               withIntermediateDirectories: true)
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
        XCTAssertEqual(changed.count, 2, "the skill file and settings.json")

        let skill = try XCTUnwrap(read(".claude/skills/aloud-voice/SKILL.md"))
        XCTAssertTrue(skill.hasPrefix("---"), "Claude Code needs the skill frontmatter")
        XCTAssertTrue(skill.contains("name: aloud-voice"))
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
        let skillBefore = try XCTUnwrap(read(".claude/skills/aloud-voice/SKILL.md"))
        let settingsBefore = try XCTUnwrap(read(".claude/settings.json"))

        let second = try installer().install(.claudeCode)
        guard case .installed(let changed) = second else { return XCTFail("expected an install result") }
        XCTAssertEqual(changed, [], "a repeat install must report that it wrote nothing")
        XCTAssertEqual(read(".claude/skills/aloud-voice/SKILL.md"), skillBefore)
        XCTAssertEqual(read(".claude/settings.json"), settingsBefore)
    }

    // Uninstall removes our four entries and leaves the rest of the user's
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
        XCTAssertEqual(try allowList().count, 6)

        try installer().uninstall(.claudeCode)

        XCTAssertEqual(try allowList(), ["Bash(git status:*)", "Read(//tmp/**)"])
        let root = try settingsJSON()
        XCTAssertEqual(root["model"] as? String, "opus", "untouched keys must survive the round trip")
        let permissions = try XCTUnwrap(root["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["deny"] as? [String], ["Bash(rm:*)"])

        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".claude/skills/aloud-voice/SKILL.md").path))
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
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".claude/skills/aloud-voice/SKILL.md").path),
                       "nothing may be written once the install is going to fail")
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

    // Somebody else's aloud-voice skill is not ours to delete.
    func testUninstallSpareAForeignSkillOfTheSameName() throws {
        try write("# my own notes about aloud\n", to: ".claude/skills/aloud-voice/SKILL.md")
        try installer().uninstall(.claudeCode)
        XCTAssertEqual(read(".claude/skills/aloud-voice/SKILL.md"), "# my own notes about aloud\n")
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
        let skill = home.appendingPathComponent(".cursor/skills/aloud-voice/SKILL.md")
        XCTAssertEqual(changed, [skill])
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

    // A skill of ours is deleted on uninstall; one that merely shares the name
    // is somebody else's file.
    func testCursorUninstallLeavesAForeignSkillAlone() throws {
        let skill = home.appendingPathComponent(".cursor/skills/aloud-voice/SKILL.md")
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
    private static let addedHarnesses: [(AgentHarness, String, String)] = [
        (.opencode, ".opencode", ".opencode/skills/aloud-voice/SKILL.md"),
        (.pi, ".pi/agent", ".pi/agent/skills/aloud-voice/SKILL.md"),
    ]

    func testAddedHarnessesInstallAsGlobalSkillFiles() throws {
        for (harness, marker, path) in Self.addedHarnesses {
            try makeDir(marker)
            guard case .installed(let changed) = try installer().install(harness) else {
                return XCTFail("\(harness.id) installs globally, not as a snippet")
            }
            let skill = home.appendingPathComponent(path)
            XCTAssertEqual(changed, [skill], "\(harness.id) wrote somewhere unexpected")

            let text = try XCTUnwrap(read(path))
            XCTAssertTrue(text.hasPrefix("---\n"), "skills are read from their frontmatter")
            XCTAssertTrue(text.contains("name: aloud-voice"))
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
            try makeDir(marker)
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
            try makeDir(marker)
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
            try makeDir(marker)
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
                try fm.createDirectory(at: scratch.appendingPathComponent(marker, isDirectory: true),
                                       withIntermediateDirectories: true)
                let found = HarnessInstaller(home: scratch, command: Self.command).detect().map(\.harness)
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

    // Only Claude Code has an allowlist that would otherwise stop the first
    // `listen` for a permission prompt. OpenCode's agents default to allowing
    // bash and pi has no allowlist concept at all, so writing one for them
    // would be editing a config file for no reason — and worse, this test
    // catches the version of that mistake where they reach for *Claude Code's*
    // settings.json because they share the install branch.
    func testAHarnessWithoutAnAllowlistNeverTouchesClaudeCodesSettings() throws {
        try write("{\"model\":\"opus\"}", to: ".claude/settings.json")
        for (harness, marker, _) in Self.addedHarnesses {
            try makeDir(marker)
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
    func testInstructionsTellTheAgentTheFiveThingsThatMatter() {
        let body = AgentVoiceInstructions.body(harness: .claudeCode, command: "aloud")
        XCTAssertTrue(body.contains("Speak before every listen"))
        XCTAssertTrue(body.contains("Say the context, briefly"))
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
        let custom = HarnessInstaller(home: home, command: "/opt/aloud/bin/aloud")
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
            let installer = HarnessInstaller(home: home, command: command)
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
        let skill = try XCTUnwrap(read(".claude/skills/aloud-voice/SKILL.md"))
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
        let installer = HarnessInstaller(home: home, command: spaced)
        _ = try installer.install(.claudeCode)

        let skill = try XCTUnwrap(read(".claude/skills/aloud-voice/SKILL.md"))
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
