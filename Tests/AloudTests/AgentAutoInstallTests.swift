import XCTest
@testable import Aloud

// Installing a skill is not enough on its own. A skill file is something the
// agent may consult if it thinks to; the harness's *global instructions* file
// is text it reads at the top of every session. Without a line there, an agent
// that could have asked the user out loud ends its turn instead and the feature
// only fires when somebody remembers it exists.
//
// So the install now touches two files per harness, and the second one is
// somebody's `~/.claude/CLAUDE.md` — a file people keep years of hand-written
// preferences in. Every test here exists because the corresponding mistake is
// silent: a note appended twice on every launch, a note that took the user's
// own instructions out with it, a sweep that reinstalls into a harness the user
// explicitly removed, or a note written for a harness that has nowhere to put
// one.
//
// Everything runs against an injected home directory and an injected
// UserDefaults suite. A test that touched the real `~` or `.standard` would be
// modifying the machine it runs on.
final class AgentAutoInstallTests: XCTestCase {
    private var home: URL!
    private var defaults: UserDefaults!
    private var fm: FileManager { .default }

    // Fixed suite names wiped before each test rather than a fresh UUID per
    // run, for the reason AgentSettingsTests spells out: cfprefsd rewrites the
    // plist asynchronously after tearDown, so a random name loses that race and
    // leaves a file in ~/Library/Preferences every single time.
    private static let suiteName = "aloud-agent-auto-install"
    // A second store, used only to prove the declined list lives in the
    // injected defaults rather than somewhere global.
    private static let otherSuiteName = "aloud-agent-auto-install-other"

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = fm.temporaryDirectory
            .appendingPathComponent("aloud-auto-install-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        try? fm.removeItem(at: home)
        for suite in [Self.suiteName, Self.otherSuiteName] {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            // removePersistentDomain empties the domain but leaves the plist
            // behind, so it is deleted by hand or the test litters the
            // developer's Preferences directory once per suite.
            let plist = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suite).plist")
            try? FileManager.default.removeItem(at: plist)
        }
        super.tearDown()
    }

    // Pinned rather than defaulted: the real default is the running binary's
    // own path, which under `swift test` is the test runner.
    static let command = "/Applications/Aloud.app/Contents/MacOS/Aloud"

    private func installer(defaults store: UserDefaults? = nil) -> HarnessInstaller {
        HarnessInstaller(home: home, command: Self.command, defaults: store ?? defaults)
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

    private func exists(_ relative: String) -> Bool {
        fm.fileExists(atPath: home.appendingPathComponent(relative).path)
    }

    private func noteBlockCount(in text: String) -> Int {
        text.components(separatedBy: AgentVoiceInstructions.noteMarkerStart).count - 1
    }

    // MARK: - where the note goes

    // The table is the whole feature: a note written to a path the harness does
    // not read is a file in somebody's home directory doing nothing, and it
    // looks exactly like success. These are the files each tool loads at the
    // start of every session, which is a different question from where its
    // skills live — note how few of them sit under the same root as
    // `instructionPath`.
    func testEachHarnessNamesTheGlobalFileItsAgentActuallyReads() {
        let expected: [AgentHarness: String?] = [
            .claudeCode: ".claude/CLAUDE.md",
            // OpenCode and pi keep their skills under ~/.opencode and
            // ~/.pi/agent, but read their global instructions from elsewhere.
            // Deriving one path from the other would put both notes somewhere
            // neither tool looks.
            .opencode: ".config/opencode/AGENTS.md",
            .pi: ".pi/agent/AGENTS.md",
            // Codex's instruction file already *is* ~/.codex/AGENTS.md — the
            // file the skill block is appended to. A second note there would be
            // the same words twice in one file.
            .codex: nil,
            .cursor: nil,
            .copilot: nil,
            .openclaw: nil,
            .hermes: nil,
        ]
        for harness in AgentHarness.allCases {
            XCTAssertTrue(expected.keys.contains(harness),
                          "\(harness.id) was added without saying whether it has a global note")
            XCTAssertEqual(harness.globalNotePath, expected[harness] ?? nil,
                           "\(harness.id) writes its note somewhere unexpected")
        }
    }

    // A note path that collided with the skill path would make the install
    // write the note over the skill, or the uninstall delete one while looking
    // for the other.
    func testTheNoteNeverLandsOnTheSkillFile() {
        for harness in AgentHarness.allCases {
            guard let note = harness.globalNotePath else { continue }
            XCTAssertNotEqual(note, harness.instructionPath, "\(harness.id)")
        }
    }

    // MARK: - the note itself

    // Two blocks, two files, and only one of them may be removed when the user
    // uninstalls a *skill*. Sharing the marker pair would make the block-strip
    // that empties `~/.claude/CLAUDE.md` also match the skill file, and the
    // matcher is a plain substring search, so a shared prefix is enough to
    // cross them.
    func testTheNoteMarkersAreTheirOwnPairAndNotAPrefixOfTheSkillMarkers() {
        XCTAssertNotEqual(AgentVoiceInstructions.noteMarkerStart, AgentVoiceInstructions.markerStart)
        XCTAssertNotEqual(AgentVoiceInstructions.noteMarkerEnd, AgentVoiceInstructions.markerEnd)
        XCTAssertFalse(AgentVoiceInstructions.markerStart.contains(AgentVoiceInstructions.noteMarkerStart))
        XCTAssertFalse(AgentVoiceInstructions.noteMarkerStart.contains(AgentVoiceInstructions.markerStart))
        XCTAssertFalse(AgentVoiceInstructions.noteMarkerEnd.contains(AgentVoiceInstructions.markerEnd))
        XCTAssertFalse(AgentVoiceInstructions.noteMarkerEnd.contains(AgentVoiceInstructions.noteMarkerStart))
    }

    // The note is loaded into the context of every session the user ever
    // starts, in a file they also keep their own instructions in. Brevity is
    // the whole design constraint rather than a matter of taste: it says what
    // the capability is and gets out of the way, and the skill file carries the
    // mechanics. Held as a ratio against the skill body so a reworded note
    // stays honest and a note that quietly grew into a second manual does not.
    func testTheNoteIsAPointerRatherThanASecondCopyOfTheManual() {
        let note = AgentVoiceInstructions.globalNote(harness: .claudeCode, command: Self.command)
        let body = AgentVoiceInstructions.body(harness: .claudeCode, command: Self.command)
        XCTAssertFalse(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(note.contains("Aloud"), "the note has to name the app doing the talking")
        XCTAssertLessThan(note.count, body.count / 4,
                          "this text is prepended to every session; it is a pointer, not the manual")
        // Carrying its own markers would nest a block inside a block, which is
        // the one shape `removingBlock` refuses to parse.
        XCTAssertFalse(note.contains(AgentVoiceInstructions.noteMarkerStart))
        XCTAssertFalse(note.contains(AgentVoiceInstructions.markerStart))
    }

    // The behaviour the note exists to change. An agent's default when it needs
    // a decision is to end the turn and wait, which a user who has walked away
    // does not find out about for ten minutes — so the note has to say so
    // explicitly, not merely advertise that a voice channel exists.
    func testTheNoteArguesAgainstEndingTheTurn() {
        let flowed = AgentVoiceInstructions.globalNote(harness: .claudeCode, command: Self.command)
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
        XCTAssertTrue(flowed.contains("turn"),
                      "the note must name the habit it is displacing, not just the feature it offers")
    }

    // A dev build must not tell agents to run the installed bundle — the same
    // rule the skill body follows, held again because the note is generated
    // separately and could quietly default.
    func testTheNoteFollowsTheInjectedCommand() throws {
        let custom = HarnessInstaller(home: home,
                                      command: "/opt/aloud/bin/aloud",
                                      defaults: defaults)
        _ = try custom.install(.claudeCode)
        let note = try XCTUnwrap(read(".claude/CLAUDE.md"))
        XCTAssertTrue(note.contains("/opt/aloud/bin/aloud"),
                      "the note points at whichever binary this build installed")
    }

    // MARK: - install

    func testInstallWritesTheGlobalNoteAlongsideTheSkill() throws {
        guard case .installed(let changed) = try installer().install(.claudeCode) else {
            return XCTFail("expected a real install")
        }
        let note = home.appendingPathComponent(".claude/CLAUDE.md")
        XCTAssertEqual(changed.count, 3, "settings.json, the note, and the skill")
        XCTAssertTrue(changed.contains(note), "the note is a file we wrote and must be reported as one")

        let text = try XCTUnwrap(read(".claude/CLAUDE.md"))
        XCTAssertTrue(text.contains(AgentVoiceInstructions.noteMarkerStart))
        XCTAssertTrue(text.contains(AgentVoiceInstructions.noteMarkerEnd))
        XCTAssertTrue(text.contains(AgentVoiceInstructions.globalNote(harness: .claudeCode, command: Self.command)))
        XCTAssertTrue(exists(".claude/skills/aloud-voice/SKILL.md"), "the skill still gets written")
    }

    // The file we are appending to may hold years of somebody's own notes. It
    // is the single most expensive file in this feature to get wrong, so the
    // content on both sides of our block is checked byte for byte rather than
    // by `contains`.
    func testTheNoteIsAppendedWithoutDisturbingWhatIsAlreadyThere() throws {
        let mine = "# My instructions\n\nAlways use tabs.\n"
        try write(mine, to: ".claude/CLAUDE.md")

        _ = try installer().install(.claudeCode)
        let text = try XCTUnwrap(read(".claude/CLAUDE.md"))
        XCTAssertTrue(text.hasPrefix(mine), "the user's own text stays where they put it, at the top")
        XCTAssertEqual(noteBlockCount(in: text), 1)
    }

    // Reopening Settings and pressing the button again is the normal case, and
    // so is a launch-time sweep. A note that appends rather than replaces would
    // grow the user's CLAUDE.md by a block per launch, forever.
    func testASecondInstallLeavesExactlyOneNoteBlock() throws {
        try write("# My instructions\n", to: ".claude/CLAUDE.md")
        _ = try installer().install(.claudeCode)
        let first = try XCTUnwrap(read(".claude/CLAUDE.md"))

        guard case .installed(let changed) = try installer().install(.claudeCode) else {
            return XCTFail("expected an install result")
        }
        XCTAssertEqual(changed, [], "a repeat install must report that it wrote nothing")
        XCTAssertEqual(read(".claude/CLAUDE.md"), first, "byte-identical, not merely equivalent")
        XCTAssertEqual(noteBlockCount(in: first), 1)
    }

    // A note is never a reason to create a config directory. OpenCode's global
    // instructions move with XDG_CONFIG_HOME, so on a Mac that has relocated
    // them, writing ~/.config/opencode/AGENTS.md would invent a folder and
    // leave a file OpenCode never reads.
    func testNoNoteIsWrittenWhereTheHarnessKeepsNoConfigDirectory() throws {
        try makeDir(".opencode")
        _ = try installer().install(.opencode)
        XCTAssertNil(read(".config/opencode/AGENTS.md"))
        XCTAssertFalse(exists(".config/opencode"),
                       "the directory itself must not be conjured either")
        XCTAssertNotNil(read(".opencode/skills/aloud-voice/SKILL.md"), "the skill still installs")
    }

    // Both note-carrying harnesses whose file is not also their skill file. pi
    // and OpenCode reuse the same branch, which is the claim worth holding: if
    // adding a note ever needs a second code path, the abstraction is wrong.
    func testEveryHarnessWithANoteGetsOneWhereverItsFileLives() throws {
        for harness in AgentHarness.allCases {
            guard let path = harness.globalNotePath else { continue }
            let scratch = home.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            let installer = HarnessInstaller(home: scratch, command: Self.command, defaults: defaults)
            // The note is only written into a directory the harness already
            // keeps its config in — we never create one (see the XDG rule in
            // installGlobalNote), so the test has to look like a real install.
            try fm.createDirectory(at: scratch.appendingPathComponent(path)
                                        .deletingLastPathComponent(),
                                   withIntermediateDirectories: true)

            _ = try installer.install(harness)
            let note = try XCTUnwrap(try? String(contentsOf: scratch.appendingPathComponent(path),
                                                 encoding: .utf8),
                                     "\(harness.id) wrote no note to \(path)")
            XCTAssertEqual(note.components(separatedBy: AgentVoiceInstructions.noteMarkerStart).count - 1, 1,
                           "\(harness.id)")
        }
    }

    // MARK: - harnesses with nowhere to put a note

    // Codex has no note path because its instruction file already is the file
    // the skill block is appended to. Writing a note as well would put two
    // Aloud sections in one file, and the pair of markers that made that legal
    // is exactly what would hide it.
    func testCodexGetsTheSkillBlockAndNoSecondNoteBlock() throws {
        _ = try installer().install(.codex)
        let text = try XCTUnwrap(read(".codex/AGENTS.md"))
        XCTAssertTrue(text.contains(AgentVoiceInstructions.markerStart))
        XCTAssertEqual(noteBlockCount(in: text), 0,
                       "codex's AGENTS.md already carries the instructions; a note here is the same words twice")
    }

    // A harness with no note path must not have one invented for it — the
    // failure mode is a file appearing in a home directory for a tool that
    // never reads it, and nothing ever cleaning it up.
    func testAHarnessWithoutANoteWritesOnlyWhereItAlwaysDid() throws {
        try makeDir(".cursor")
        XCTAssertNil(AgentHarness.cursor.globalNotePath)
        _ = try installer().install(.cursor)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: home.path).sorted(), [".cursor"])
        XCTAssertFalse(exists(".cursor/AGENTS.md"))
        XCTAssertFalse(exists(".cursor/CLAUDE.md"))
    }

    // MARK: - uninstall

    // The mirror of the append test, and the one that costs the user real work
    // if it is wrong. Their text has to come back exactly as it went in.
    func testUninstallTakesTheNoteAndLeavesTheUsersOwnText() throws {
        let mine = "# My instructions\n\nAlways use tabs.\n"
        try write(mine, to: ".claude/CLAUDE.md")
        _ = try installer().install(.claudeCode)

        // Text added after our block, the way somebody editing the file would.
        let withBlock = try XCTUnwrap(read(".claude/CLAUDE.md"))
        try write(withBlock + "\nAnd never commit to main.\n", to: ".claude/CLAUDE.md")

        try installer().uninstall(.claudeCode)
        XCTAssertEqual(read(".claude/CLAUDE.md"),
                       mine + "\nAnd never commit to main.\n",
                       "uninstall must take our block and the blank line we added, and nothing else")
        XCTAssertFalse(exists(".claude/skills/aloud-voice/SKILL.md"), "the skill goes too")
    }

    // We created the file, so removing our block should not leave an empty
    // CLAUDE.md behind for the harness to load — the same rule the codex
    // AGENTS.md already follows.
    func testUninstallDeletesANoteFileThatHeldNothingElse() throws {
        _ = try installer().install(.claudeCode)
        XCTAssertTrue(exists(".claude/CLAUDE.md"))
        try installer().uninstall(.claudeCode)
        XCTAssertFalse(exists(".claude/CLAUDE.md"))
    }

    // Uninstalling something that was never installed is a button the Settings
    // pane can offer at any time, and it must not conjure files.
    func testUninstallingAHarnessThatWasNeverInstalledIsHarmless() throws {
        XCTAssertNoThrow(try installer().uninstall(.claudeCode))
        XCTAssertFalse(exists(".claude/CLAUDE.md"))
    }

    // MARK: - the launch-time sweep

    func testInstallAllDetectedInstallsEveryGlobalHarnessItFinds() throws {
        try makeDir(".claude")
        try makeDir(".codex")

        XCTAssertEqual(installer().installAllDetected(), [.claudeCode, .codex])
        XCTAssertTrue(installer().isInstalled(.claudeCode))
        XCTAssertTrue(installer().isInstalled(.codex))
        XCTAssertTrue(exists(".claude/CLAUDE.md"))
    }

    // The sweep runs on every launch, so "already installed" has to mean
    // "nothing to report" — otherwise the pane announces an install the user
    // did not just get, every single time they open the app.
    func testTheSweepReportsOnlyTheHarnessesItActuallyChanged() throws {
        try makeDir(".claude")
        try makeDir(".codex")
        _ = try installer().install(.claudeCode)

        XCTAssertEqual(installer().installAllDetected(), [.codex],
                       "claude-code was already installed and is not news")
        XCTAssertEqual(installer().installAllDetected(), [],
                       "and a sweep with nothing left to do reports nothing")
    }

    // Copilot's instructions belong in the user's repo. A sweep that ran at
    // launch and wrote there would be Aloud creating files in a git working
    // tree nobody pointed it at — which is why the snippet exists at all.
    func testTheSweepNeverInstallsIntoAPerProjectHarness() throws {
        try makeDir(".config/github-copilot")
        XCTAssertEqual(installer().detect().map(\.harness), [.copilot], "it is detected…")
        XCTAssertEqual(installer().installAllDetected(), [], "…and still not installed")
        XCTAssertFalse(exists(".github/copilot-instructions.md"))
        XCTAssertFalse(exists(".github"))
    }

    // MARK: - remembering a refusal

    // The point of the whole declined list. Without it, a user who removes
    // Aloud from Claude Code gets it back on the next launch, and the only way
    // out is to stop using the app — an auto-installer that cannot be told
    // "no" is a bug that reads as malware.
    func testAHarnessTheUserRemovedIsNotReinstalledByTheNextSweep() throws {
        try makeDir(".claude")
        try makeDir(".codex")
        let installer = self.installer()
        XCTAssertEqual(installer.installAllDetected(), [.claudeCode, .codex])

        try installer.uninstall(.claudeCode)
        XCTAssertEqual(installer.installAllDetected(), [],
                       "the sweep must respect a removal it can see the user made")
        XCTAssertFalse(installer.isInstalled(.claudeCode))
        XCTAssertFalse(exists(".claude/CLAUDE.md"), "and the note stays gone")
    }

    // Declining is per harness. A single flag would mean removing Aloud from
    // one tool silently opting the user out of every tool they install later.
    func testDecliningOneHarnessLeavesTheRestOfTheSweepWorking() throws {
        try makeDir(".claude")
        try makeDir(".codex")
        let installer = self.installer()
        _ = installer.installAllDetected()
        try installer.uninstall(.codex)

        // A harness that appears after the refusal is still picked up.
        try makeDir(".cursor")
        XCTAssertEqual(installer.installAllDetected(), [.cursor])
        XCTAssertFalse(installer.isInstalled(.codex), "the refusal stands")
        XCTAssertTrue(installer.isInstalled(.claudeCode), "and the harness they kept is untouched")
    }

    // The list is state about the user, not about the home directory, so it
    // belongs in the defaults we were handed. If it lived in `.standard` this
    // test would fail — and so would every other test in the suite, on the
    // second run, on whichever machine ran it first.
    func testTheDeclinedListLivesInTheInjectedDefaults() throws {
        try makeDir(".claude")
        let first = installer()
        _ = first.installAllDetected()
        try first.uninstall(.claudeCode)
        XCTAssertEqual(first.installAllDetected(), [])

        let other = try XCTUnwrap(UserDefaults(suiteName: Self.otherSuiteName))
        other.removePersistentDomain(forName: Self.otherSuiteName)
        XCTAssertEqual(installer(defaults: other).installAllDetected(), [.claudeCode],
                       "a different store knows nothing of the refusal, so the memory is in the store")
    }
}
