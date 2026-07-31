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

    private func installer() -> HarnessInstaller {
        HarnessInstaller(home: home)
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

        XCTAssertEqual(try allowList(), HarnessInstaller.claudePermissionEntries)
        XCTAssertTrue(installer().isInstalled(.claudeCode))
    }

    // The first `listen` stopping for a Bash permission prompt would break a
    // feature whose entire point is not touching the keyboard.
    func testAllowlistCoversEveryProdVerb() throws {
        _ = try installer().install(.claudeCode)
        let allow = try allowList()
        for verb in ["claim", "listen", "speak", "release"] {
            XCTAssertTrue(allow.contains("Bash(aloud \(verb):*)"), "missing an allowlist entry for \(verb)")
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
            XCTAssertTrue(snippet.contains("Bash(aloud listen:*)"))
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
        XCTAssertTrue(body.lowercased().contains("never retry in\na loop") || body.lowercased().contains("do not spin"))
        for verb in ["claim", "listen", "speak", "release"] {
            XCTAssertTrue(body.contains("\(verb) "), "the mechanics must mention `\(verb)`")
        }
    }

    // One body, four wrappers. If a harness ever grew its own copy of the text
    // the two would drift within a release.
    func testEveryHarnessGetsTheSameBody() {
        let bodies = AgentHarness.allCases.map {
            AgentVoiceInstructions.body(harness: $0, command: "aloud")
                .replacingOccurrences(of: $0.id, with: "<id>")
        }
        XCTAssertEqual(Set(bodies).count, 1, "the instruction text must have exactly one source")
    }

    // A dev build must not tell agents to run the installed bundle.
    func testTheCommandIsInjectable() throws {
        let custom = HarnessInstaller(home: home, command: "/opt/aloud/bin/aloud")
        _ = try custom.install(.codex)
        XCTAssertTrue(try XCTUnwrap(read(".codex/AGENTS.md")).contains("/opt/aloud/bin/aloud claim"))
    }
}
