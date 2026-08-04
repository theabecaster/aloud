import XCTest
@testable import Aloud

// Uninstall is the one moment where forgetting the harness configs is silent
// and lasting: the app goes to the Trash, and up to three tools keep a skill
// telling their agent to run a binary that no longer exists. The user meets
// that weeks later, inside a tool they will not connect to an app they removed.
//
// So these tests are about the sweep itself — that it reaches every harness,
// that it survives homes it has never touched or that somebody edited by hand,
// and above all that one harness it cannot clean does not take the others down
// with it. Everything runs against an injected home; a test that reached the
// developer's real `~` would be uninstalling from the machine it runs on.
final class UninstallerHarnessTests: XCTestCase {
    private var home: URL!
    private var fm: FileManager { .default }
    private static let command = "/Applications/Aloud.app/Contents/MacOS/Aloud"

    // The installer keeps state about the user — which harnesses they removed,
    // which permission verbs they have been offered — and defaults to
    // `UserDefaults.standard`. Left uninjected these tests wrote
    // `agentDeclinedHarnesses` and friends into the xctest tool's own domain,
    // shared with every other xctest process on the machine and persisted
    // across runs. Nothing reads them today, which is exactly the problem:
    // `installAllDetected()` short-circuits on `declinedHarnesses`, so the
    // first test here that called it would return `[]` and pass for the wrong
    // reason on the second run. One fixed suite, wiped on the way in, and the
    // plist deleted on the way out (see AgentAutoInstallTests for why the name
    // is stable rather than random).
    private static let suiteName = "aloud-uninstaller-harness-tests"
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        home = fm.temporaryDirectory
            .appendingPathComponent("aloud-uninstall-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        try? fm.removeItem(at: home)
        forgetTestDefaults(Self.suiteName)
    }

    private func installer() -> HarnessInstaller {
        HarnessInstaller(home: home, command: Self.command, defaults: defaults)
    }

    private func sweep() -> [Uninstaller.HarnessCleanupFailure] {
        Uninstaller.removeHarnessInstalls(using: installer())
    }

    private func write(_ text: String, to relative: String) throws {
        let url = home.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ relative: String) -> String? {
        try? String(contentsOf: home.appendingPathComponent(relative), encoding: .utf8)
    }

    private func exists(_ relative: String) -> Bool {
        fm.fileExists(atPath: home.appendingPathComponent(relative).path)
    }

    private func allowList(_ relative: String = ".claude/settings.json") throws -> [String] {
        let data = try Data(contentsOf: home.appendingPathComponent(relative))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let permissions = try XCTUnwrap(root["permissions"] as? [String: Any])
        return try XCTUnwrap(permissions["allow"] as? [String])
    }

    // Two harnesses carry an allowlist now, in two files and two dialects, and
    // the sweep has to reach both. Cursor's was added late — its row installed
    // a skill and no allowlist for a while — so it is the one most likely to be
    // forgotten again here.
    private static let cursorConfigPath = ".cursor/cli-config.json"

    // Every harness we are able to write to. Derived from the table rather than
    // listed by hand, so a harness added later is swept by these tests the day
    // it is added — the failure mode this whole file exists to prevent is
    // precisely the one where somebody adds a row and forgets the sweep.
    private var globalHarnesses: [AgentHarness] {
        AgentHarness.allCases.filter { $0.scope == .global }
    }

    // The whole point: a full install, then a full uninstall, leaves nothing of
    // ours anywhere — instruction files, skill directories, and every
    // allowlist entry alike.
    func testUninstallUnwritesEveryHarnessWeInstalledTo() throws {
        for harness in globalHarnesses {
            _ = try installer().install(harness)
        }
        XCTAssertEqual(try allowList().count, AgentVoiceInstructions.verbs.count)
        XCTAssertEqual(try allowList(Self.cursorConfigPath).count, AgentVoiceInstructions.verbs.count)

        XCTAssertEqual(sweep(), [])

        XCTAssertFalse(exists(".claude/skills/aloud-agent-speak/SKILL.md"))
        XCTAssertFalse(exists(".claude/skills/aloud-agent-speak"))
        XCTAssertFalse(exists(".cursor/skills/aloud-agent-speak/SKILL.md"))
        XCTAssertFalse(exists(".codex/AGENTS.md"), "the file held nothing but our section")
        // The harnesses added after launch. Spelled out as literal paths as
        // well as being covered by the loop below, because a typo'd path in the
        // table would make an `isInstalled` check pass by looking in the same
        // wrong place twice.
        XCTAssertFalse(exists(".opencode/skills/aloud-agent-speak/SKILL.md"))
        XCTAssertFalse(exists(".pi/agent/skills/aloud-agent-speak/SKILL.md"))
        XCTAssertFalse(exists(".openclaw/skills/aloud-agent-speak/SKILL.md"))
        XCTAssertFalse(exists(".hermes/skills/aloud-agent-speak/SKILL.md"))

        XCTAssertEqual(try allowList(), [], "the allowlist must not keep permitting a binary that is going away")
        XCTAssertEqual(try allowList(Self.cursorConfigPath), [],
                       "Cursor's allowlist is ours to clean up too, in its own file and its own dialect")
        for harness in AgentHarness.allCases {
            XCTAssertFalse(installer().isInstalled(harness))
            XCTAssertFalse(exists(harness.instructionPath),
                           "\(harness.id) kept its instructions after the sweep")
        }
    }

    // The sweep walks `AgentHarness.allCases`, which is what makes a new row
    // swept the day it is added — but "it is driven off allCases" is a claim
    // about the code, and this is the test that makes it a claim about the
    // behaviour. Everything below is derived from the table, so a row added
    // without a thought here is still covered, and a row that quietly stops
    // being swept fails.
    func testTheSweepIsDrivenOffTheTableSoNewRowsAreCoveredTheDayTheyAreAdded() throws {
        for harness in globalHarnesses {
            _ = try installer().install(harness)
            XCTAssertTrue(exists(harness.instructionPath), "\(harness.id) did not install where the table says")
        }
        // Every allowlist we know how to write is non-empty before the sweep,
        // whichever file and dialect it uses.
        for harness in AgentHarness.allCases {
            guard let url = installer().allowlistURL(for: harness) else { continue }
            let relative = url.path.replacingOccurrences(of: home.path + "/", with: "")
            XCTAssertEqual(try allowList(relative).count, AgentVoiceInstructions.verbs.count, "\(harness.id) never wrote its allowlist")
        }

        XCTAssertEqual(sweep(), [])

        for harness in AgentHarness.allCases {
            XCTAssertFalse(installer().isInstalled(harness))
            XCTAssertFalse(exists(harness.instructionPath), "\(harness.id) kept its instructions")
            guard let url = installer().allowlistURL(for: harness) else { continue }
            let relative = url.path.replacingOccurrences(of: home.path + "/", with: "")
            XCTAssertEqual(try allowList(relative), [], "\(harness.id) kept its allowlist entries")
        }
    }

    // Uninstall runs on every Mac, including the many where agent voice was
    // never switched on. It must not create a config, a directory, or a
    // failure out of nothing.
    func testUninstallOnAHomeWeNeverTouchedDoesNothingAtAll() {
        XCTAssertEqual(sweep(), [])
        XCTAssertEqual(try? fm.contentsOfDirectory(atPath: home.path), [],
                       "an untouched home must stay untouched, not gain an empty .claude")
    }

    // Between install and uninstall the user is free to edit, move, or delete
    // any of these files — they are the harness's, not ours. Every branch has
    // to no-op rather than throw or take a neighbour's text with it.
    func testHandEditedAndDeletedConfigsAreSurvivable() throws {
        for harness in globalHarnesses {
            _ = try installer().install(harness)
        }

        // Deleted outright.
        try fm.removeItem(at: home.appendingPathComponent(".cursor/skills/aloud-agent-speak"))
        // Rewritten by hand, markers and all, into something that is now theirs.
        try write("# my own aloud notes\n", to: ".claude/skills/aloud-agent-speak/SKILL.md")
        // Our section pulled out, their own text left behind.
        try write("Always use tabs.\n", to: ".codex/AGENTS.md")

        XCTAssertEqual(sweep(), [])
        XCTAssertEqual(read(".claude/skills/aloud-agent-speak/SKILL.md"), "# my own aloud notes\n",
                       "a file that no longer carries our marker is not ours to delete")
        XCTAssertEqual(read(".codex/AGENTS.md"), "Always use tabs.\n")
        XCTAssertEqual(try allowList(), [], "the allowlist entries are still ours even if the skill file is not")
        XCTAssertEqual(try allowList(Self.cursorConfigPath), [],
                       "the same holds for Cursor: the skill was deleted by hand, the allowlist entries were not")
    }

    // The failure that must not cascade. A settings.json we cannot parse is a
    // file we refuse to rewrite — but the user is uninstalling, the app is
    // already on its way to the Trash, and Codex and Cursor have no idea. One
    // harness reporting a problem cannot mean the other two keep their skills.
    func testOneHarnessFailingStillLeavesTheOthersClean() throws {
        for harness in globalHarnesses {
            _ = try installer().install(harness)
        }
        let broken = "{ \"permissions\": { \"allow\": [ ,, }"
        try write(broken, to: ".claude/settings.json")

        let failures = sweep()
        XCTAssertEqual(failures.map(\.harness), [.claudeCode], "exactly the harness that could not be cleaned")
        XCTAssertFalse(try XCTUnwrap(failures.first?.reason).isEmpty, "the failure has to say what happened")

        XCTAssertEqual(read(".claude/settings.json"), broken, "a file we cannot parse is a file we do not write")
        XCTAssertFalse(exists(".codex/AGENTS.md"))
        XCTAssertFalse(exists(".cursor/skills/aloud-agent-speak/SKILL.md"))
        XCTAssertFalse(exists(".opencode/skills/aloud-agent-speak/SKILL.md"))
        XCTAssertFalse(exists(".pi/agent/skills/aloud-agent-speak/SKILL.md"))
        XCTAssertFalse(exists(".openclaw/skills/aloud-agent-speak/SKILL.md"))
        XCTAssertFalse(exists(".hermes/skills/aloud-agent-speak/SKILL.md"))
        // Including the other harness that has an allowlist: two allowlists in
        // two files means one unreadable file must not strand the other.
        XCTAssertEqual(try allowList(Self.cursorConfigPath), [])
        // Even the failing harness gets as far as it can: the skill file goes,
        // only the allowlist is left stale.
        XCTAssertFalse(exists(".claude/skills/aloud-agent-speak/SKILL.md"))
    }

    // Removing the permission entries must not turn into rewriting somebody's
    // settings.json. Their other rules, and every key we never look at, come
    // out the far side unchanged.
    func testTheRestOfSettingsJsonSurvivesTheSweep() throws {
        try write("""
        {
          "model": "opus",
          "statusLine": {"type": "command", "command": "~/bin/statusline"},
          "permissions": {
            "allow": ["Bash(git status:*)", "Read(//tmp/**)"],
            "deny": ["Bash(rm:*)"],
            "defaultMode": "acceptEdits"
          }
        }
        """, to: ".claude/settings.json")

        _ = try installer().install(.claudeCode)
        XCTAssertEqual(sweep(), [])

        let data = try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertEqual((root["statusLine"] as? [String: Any])?["command"] as? String, "~/bin/statusline")
        let permissions = try XCTUnwrap(root["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["allow"] as? [String], ["Bash(git status:*)", "Read(//tmp/**)"])
        XCTAssertEqual(permissions["deny"] as? [String], ["Bash(rm:*)"])
        XCTAssertEqual(permissions["defaultMode"] as? String, "acceptEdits")
    }

    // Copilot is per project: we handed the user a snippet and never wrote into
    // their repo, so there is nothing to remove and nothing to report. Included
    // because the sweep asks every harness, and the one that has no on-disk
    // state must not answer with a failure.
    func testTheSweepAsksEveryHarnessIncludingTheOnesWeNeverWroteTo() throws {
        // Claude Code, Codex, Cursor, Copilot at launch; OpenCode, pi, OpenClaw
        // and Hermes added after. The count is asserted so that adding a
        // harness without revisiting this file is a failing test rather than a
        // silent gap.
        XCTAssertEqual(AgentHarness.allCases.count, 8)
        for harness in AgentHarness.allCases where harness.scope == .perProject {
            _ = try installer().install(harness)
        }
        XCTAssertEqual(sweep(), [])
        XCTAssertEqual(try? fm.contentsOfDirectory(atPath: home.path), [],
                       "a snippet harness writes nothing, so the sweep has nothing to find")
    }

    // Uninstall is best-effort and one-shot, but nothing stops the Settings
    // pane from calling it twice, and a second sweep on an already-clean home
    // must be as quiet as the first.
    func testASecondSweepIsStillClean() throws {
        _ = try installer().install(.claudeCode)
        XCTAssertEqual(sweep(), [])
        XCTAssertEqual(sweep(), [])
    }
}
