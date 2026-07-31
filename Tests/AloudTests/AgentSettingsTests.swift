import XCTest
@testable import Aloud

// The master switch defaults to "on once at least one harness is installed",
// which is a derived default — and derived defaults are exactly where a user's
// explicit choice gets silently overwritten later. These pin the boundary.
final class AgentSettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "aloud-agent-settings-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func store() -> SettingsStore { SettingsStore(defaults: defaults) }

    func testDefaultsOffWithNoHarnessInstalled() {
        // Before any harness exists there is nothing to grant access to, so
        // shipping this on would be a permission nobody asked for.
        XCTAssertFalse(store().agentVoiceEnabled)
    }

    func testInstallingTheFirstHarnessTurnsItOn() {
        let s = store()
        s.installedHarnesses = ["claude-code"]
        s.noteHarnessesChanged()
        XCTAssertTrue(s.agentVoiceEnabled)
        XCTAssertTrue(SettingsStore(defaults: defaults).agentVoiceEnabled,
                      "the derived default has to survive a relaunch")
    }

    func testRemovingTheLastHarnessTurnsItBackOff() {
        let s = store()
        s.installedHarnesses = ["claude-code"]
        s.noteHarnessesChanged()
        s.installedHarnesses = []
        s.noteHarnessesChanged()
        XCTAssertFalse(s.agentVoiceEnabled)
    }

    // The one that matters: a user who deliberately turned voice off must not
    // have it switched back on by installing another harness later.
    func testAnExplicitChoiceIsNeverOverriddenByLaterInstalls() {
        let s = store()
        s.installedHarnesses = ["claude-code"]
        s.noteHarnessesChanged()
        XCTAssertTrue(s.agentVoiceEnabled)

        s.agentVoiceEnabled = false            // the user says no
        s.installedHarnesses = ["claude-code", "codex"]
        s.noteHarnessesChanged()
        XCTAssertFalse(s.agentVoiceEnabled, "installing a harness must not re-grant microphone access")

        XCTAssertFalse(SettingsStore(defaults: defaults).agentVoiceEnabled,
                       "and the refusal has to persist across a relaunch")
    }

    func testExplicitlyOnSurvivesRemovingEveryHarness() {
        let s = store()
        s.agentVoiceEnabled = true
        s.installedHarnesses = []
        s.noteHarnessesChanged()
        XCTAssertTrue(s.agentVoiceEnabled)
    }

    func testConsentModeDefaultsToConfirmByVoice() {
        // The only mode that is both hands-free and gated, which is the point
        // of a feature used without looking at the screen.
        XCTAssertEqual(store().agentConsentMode, .confirmByVoice)
    }

    func testConsentModePersists() {
        let s = store()
        s.agentConsentMode = .confirmOnScreen
        XCTAssertEqual(SettingsStore(defaults: defaults).agentConsentMode, .confirmOnScreen)
    }

    // The spoken prompt names the caller only when there is real ambiguity —
    // with one harness installed, "Claude Code wants to listen" is just noise.
    func testHarnessIsNamedOnlyWhenSeveralAreInstalled() {
        let s = store()
        s.installedHarnesses = ["claude-code"]
        XCTAssertFalse(s.namesHarnessWhenSpeaking)
        s.installedHarnesses = ["claude-code", "codex"]
        XCTAssertTrue(s.namesHarnessWhenSpeaking)
    }
}
