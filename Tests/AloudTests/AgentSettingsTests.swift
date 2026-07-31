import XCTest
@testable import Aloud

// Agent voice ships behind an experimental gate. The gate is the feature's
// only on/off control: off means Settings shows no Agents section and every
// agent call is refused. These pin the "off unless asked for" contract, since
// a gate that quietly turns itself on is worse than no gate.
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

    func testExperimentIsOffOnAFreshInstall() {
        let s = store()
        XCTAssertFalse(s.experimentalAgentVoice)
        XCTAssertFalse(s.agentVoiceAvailable,
                       "nothing may reach an agent before the user opts in")
    }

    func testOptingInPersists() {
        let s = store()
        s.experimentalAgentVoice = true
        XCTAssertTrue(SettingsStore(defaults: defaults).experimentalAgentVoice)
        XCTAssertTrue(SettingsStore(defaults: defaults).agentVoiceAvailable)
    }

    func testTurningItOffMakesTheFeatureUnavailableAgain() {
        let s = store()
        s.experimentalAgentVoice = true
        s.installedHarnesses = ["claude-code", "codex"]

        s.experimentalAgentVoice = false
        XCTAssertFalse(s.agentVoiceAvailable,
                       "the gate has to win regardless of what is installed underneath")
        // Turning the experiment off is not an uninstall: the harnesses stay
        // wired up so switching it back on doesn't mean setting them up again.
        XCTAssertEqual(s.installedHarnesses, ["claude-code", "codex"])
    }

    // The gate cannot be inferred from whether a harness is installed — the
    // install UI lives on the page the gate reveals, so a harness can never
    // exist first. Guards against reintroducing a derived default.
    func testInstallingHarnessesNeverOpensTheGate() {
        let s = store()
        s.installedHarnesses = ["claude-code"]
        XCTAssertFalse(s.experimentalAgentVoice)
        XCTAssertFalse(SettingsStore(defaults: defaults).experimentalAgentVoice)
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

    func testInstalledHarnessesPersist() {
        let s = store()
        s.installedHarnesses = ["cursor"]
        XCTAssertEqual(SettingsStore(defaults: defaults).installedHarnesses, ["cursor"])
    }
}
