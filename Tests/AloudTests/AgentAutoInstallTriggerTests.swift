import XCTest
@testable import Aloud

// When the automatic install fires, as opposed to what it writes (that is
// AgentAutoInstallTests). Three questions only this layer answers: does it
// respect the master switch, does it run once per version, and does finishing
// onboarding count as a reason to run regardless of the version marker.
@MainActor
final class AgentAutoInstallTriggerTests: XCTestCase {
    private var home: URL!
    private var defaults: UserDefaults!

    // One fixed suite for the whole class, wiped before each test rather than a
    // fresh UUID per run: `removePersistentDomain` empties the domain but
    // leaves the plist behind, and cfprefsd rewrites it asynchronously after
    // tearDown, so a random name loses that race and litters
    // ~/Library/Preferences once per test, forever. A stable name still
    // isolates and can leave at most one file, which tearDown removes.
    private static let suiteName = "com.aloud.tests.autoinstall"

    override func setUp() {
        super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-autoinstall-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: Self.suiteName)
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(Self.suiteName).plist")
        try? FileManager.default.removeItem(at: plist)
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    // A harness is only detected if the tool's own marker directory exists, so
    // every test that wants an install has to put one there first.
    private func makeClaudeCodeMarker() {
        try? FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"),
                                                 withIntermediateDirectories: true)
    }

    private func installer() -> HarnessInstaller {
        HarnessInstaller(home: home, command: "/Applications/Aloud.app/Contents/MacOS/Aloud",
                         defaults: defaults)
    }

    private func store(agentVoiceOn: Bool) -> SettingsStore {
        let store = SettingsStore(defaults: defaults)
        store.experimentalAgentVoice = agentVoiceOn
        return store
    }

    private func skillExists() -> Bool {
        FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".claude/skills/aloud-agent-speak/SKILL.md").path)
    }

    // The gate is an opt-in, and installing instructions for a feature the user
    // has not switched on would be writing into their config for something that
    // cannot run.
    func testNothingIsInstalledWhileAgentSpeakIsOff() {
        makeClaudeCodeMarker()
        AgentAutoInstall.runIfNeeded(settings: store(agentVoiceOn: false),
                                     defaults: defaults,
                                     version: "1.2.3",
                                     installer: installer())
        XCTAssertFalse(skillExists())
    }

    func testTheFirstLaunchOfAVersionInstallsIntoEveryDetectedHarness() {
        makeClaudeCodeMarker()
        let settings = store(agentVoiceOn: true)
        AgentAutoInstall.runIfNeeded(settings: settings, defaults: defaults,
                                     version: "1.2.3", installer: installer())
        XCTAssertTrue(skillExists())
        // The pane and the bridge's `status` both read this, so a silent
        // install that left it empty would under-report the feature's reach.
        XCTAssertEqual(settings.installedHarnesses, ["claude-code"])
    }

    // Second launch of the same version: the marker is the whole point, or the
    // pass would run on every single launch.
    func testTheSameVersionOnlyInstallsOnce() throws {
        makeClaudeCodeMarker()
        let settings = store(agentVoiceOn: true)
        AgentAutoInstall.runIfNeeded(settings: settings, defaults: defaults,
                                     version: "1.2.3", installer: installer())
        let skill = home.appendingPathComponent(".claude/skills/aloud-agent-speak/SKILL.md")
        try FileManager.default.removeItem(at: skill)

        AgentAutoInstall.runIfNeeded(settings: settings, defaults: defaults,
                                     version: "1.2.3", installer: installer())
        XCTAssertFalse(skillExists(), "the version marker should have stopped a second pass")
    }

    // ...and the next version is a new reason to run: the instructions travel
    // with the app, and a Mac that grew a harness since the last launch has one
    // waiting.
    func testANewVersionInstallsAgain() throws {
        makeClaudeCodeMarker()
        let settings = store(agentVoiceOn: true)
        AgentAutoInstall.runIfNeeded(settings: settings, defaults: defaults,
                                     version: "1.2.3", installer: installer())
        try FileManager.default.removeItem(
            at: home.appendingPathComponent(".claude/skills/aloud-agent-speak/SKILL.md"))

        AgentAutoInstall.runIfNeeded(settings: settings, defaults: defaults,
                                     version: "1.3.0", installer: installer())
        XCTAssertTrue(skillExists())
    }

    // Finishing onboarding is the first-launch case, and it must not be gated
    // on a version marker some earlier pass may already have written.
    func testFinishingOnboardingInstallsEvenWhenTheVersionWasAlreadySeen() throws {
        makeClaudeCodeMarker()
        let settings = store(agentVoiceOn: true)
        AgentAutoInstall.runIfNeeded(settings: settings, defaults: defaults,
                                     version: "1.2.3", installer: installer())
        try FileManager.default.removeItem(
            at: home.appendingPathComponent(".claude/skills/aloud-agent-speak/SKILL.md"))

        AgentAutoInstall.runAfterOnboarding(settings: settings, defaults: defaults,
                                            version: "1.2.3", installer: installer())
        XCTAssertTrue(skillExists())
    }

    // A user who turned Agent Speak off during onboarding gets nothing written
    // anywhere, which is the same rule as the launch pass.
    func testFinishingOnboardingWithTheFeatureOffInstallsNothing() {
        makeClaudeCodeMarker()
        AgentAutoInstall.runAfterOnboarding(settings: store(agentVoiceOn: false),
                                            defaults: defaults,
                                            version: "1.2.3",
                                            installer: installer())
        XCTAssertFalse(skillExists())
    }

    // The removal memory is the one thing that outranks the automatic pass.
    func testAHarnessTheUserRemovedStaysRemovedAcrossVersions() throws {
        makeClaudeCodeMarker()
        let settings = store(agentVoiceOn: true)
        let installer = installer()
        AgentAutoInstall.runIfNeeded(settings: settings, defaults: defaults,
                                     version: "1.2.3", installer: installer)
        try installer.uninstall(.claudeCode)
        XCTAssertFalse(skillExists())

        AgentAutoInstall.runIfNeeded(settings: settings, defaults: defaults,
                                     version: "1.3.0", installer: installer)
        XCTAssertFalse(skillExists(), "an update must not undo a Remove")
    }

    // MARK: the note on an already-installed Mac

    // Everyone who had Agent Speak before this build has the skill and no note,
    // and the automatic install skips them precisely because they are already
    // installed. The refresh is the only pass that runs on their machine, so it
    // has to be the one that writes their first note.
    func testTheRefreshWritesTheFirstNoteForAnAlreadyInstalledHarness() throws {
        makeClaudeCodeMarker()
        let installer = installer()
        _ = try installer.install(.claudeCode)
        let note = home.appendingPathComponent(".claude/CLAUDE.md")
        try FileManager.default.removeItem(at: note)
        // Pretend this install predates the note entirely.
        defaults.removeObject(forKey: "agentGlobalNoteWritten")

        _ = installer.refreshInstalled()
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))
    }

    // ...and once they have had one, deleting it is a decision that sticks.
    func testTheRefreshNeverPutsBackANoteTheUserDeleted() throws {
        makeClaudeCodeMarker()
        let installer = installer()
        _ = try installer.install(.claudeCode)
        let note = home.appendingPathComponent(".claude/CLAUDE.md")
        try FileManager.default.removeItem(at: note)

        _ = installer.refreshInstalled()
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path),
                       "a note the user removed must stay removed")
    }

    // MARK: removal has to survive a damaged note

    // The note lives in a file people edit by hand, so its markers can end up
    // orphaned. That must not take the uninstall down with it: the skill and
    // the shell permissions are the things that matter, and leaving them behind
    // for a feature the user just removed is the worst outcome available.
    func testUninstallStillRemovesTheSkillWhenTheNoteMarkersAreDamaged() throws {
        makeClaudeCodeMarker()
        let installer = installer()
        _ = try installer.install(.claudeCode)

        let note = home.appendingPathComponent(".claude/CLAUDE.md")
        try (AgentVoiceInstructions.noteMarkerStart + "\northopaned, no end marker\n")
            .write(to: note, atomically: true, encoding: .utf8)

        try installer.uninstall(.claudeCode)
        XCTAssertFalse(skillExists(), "a damaged note must not strand the skill")
        XCTAssertTrue(installer.declinedHarnesses.contains("claude-code"))
    }

    // A refresh is not the user changing their mind. It runs on every launch,
    // so treating it as consent would quietly erase the removal record and let
    // the next version reinstall what they took away.
    func testARefreshDoesNotForgetThatTheUserRemovedAHarness() throws {
        makeClaudeCodeMarker()
        let installer = installer()
        _ = try installer.install(.claudeCode)
        try installer.uninstall(.claudeCode)
        XCTAssertTrue(installer.declinedHarnesses.contains("claude-code"))

        _ = installer.refreshInstalled()
        XCTAssertTrue(installer.declinedHarnesses.contains("claude-code"),
                      "only an install the user asked for clears the record")
    }

    // MARK: the consent defaults

    // Agents are let in on sight unless the user says otherwise, and existing
    // installs are brought onto that once — they are carrying a default nobody
    // chose.
    func testConsentDefaultsAreAppliedOnce() {
        defaults.set(AgentConsentMode.confirmByVoice.rawValue, forKey: "agentConsentMode")
        defaults.set(true, forKey: "agentAsksOutLoud")

        Migration.applyAgentConsentDefaultsIfNeeded(defaults)
        XCTAssertEqual(defaults.string(forKey: "agentConsentMode"), AgentConsentMode.open.rawValue)
        XCTAssertEqual(defaults.bool(forKey: "agentAsksOutLoud"), false)
    }

    // ...and never again, because after this everything in there is the user's
    // own choice.
    func testAChoiceMadeAfterTheMigrationIsLeftAlone() {
        Migration.applyAgentConsentDefaultsIfNeeded(defaults)
        let store = SettingsStore(defaults: defaults)
        store.agentAsksFirst = true
        store.agentAsksOutLoud = true
        XCTAssertEqual(store.agentConsentMode, .confirmByVoice)

        Migration.applyAgentConsentDefaultsIfNeeded(defaults)
        XCTAssertEqual(SettingsStore(defaults: defaults).agentConsentMode, .confirmByVoice)
        XCTAssertTrue(SettingsStore(defaults: defaults).agentAsksOutLoud)
    }
}

// A development build must not touch the user's home.
//
// The command written into every one of these files is the path of the binary
// that wrote it. From `.build/debug/Aloud` that is a scratch build in a
// checkout: each launch rewrote the global note, the skill file and the
// permission entries for every harness on the Mac to point at a binary that
// the next `swift build` replaces — and the first sign of it is the user's own
// agents invoking it. Half a dozen of the user's own files, silently, per run.
extension AgentAutoInstallTriggerTests {

    @MainActor
    func testADevelopmentBuildIsNotAllowedToWriteIntoTheHome() {
        // The test host is not an .app bundle, which is exactly the case this
        // guard exists for.
        XCTAssertFalse(AgentAutoInstall.mayWriteToHome,
                       "a bare binary is claiming the right to rewrite the user's instruction files")
    }
}
