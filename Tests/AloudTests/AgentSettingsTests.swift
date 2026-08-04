import XCTest
@testable import Aloud

// Agent voice ships behind an experimental gate. The gate is the feature's
// only on/off control: off means Settings shows no Agents section and every
// agent call is refused. These pin the "off unless asked for" contract, since
// a gate that quietly turns itself on is worse than no gate.
final class AgentSettingsTests: XCTestCase {
    // One fixed suite for the whole class, wiped before each test rather than a
    // fresh UUID per run. cfprefsd rewrites the plist asynchronously after
    // tearDown, so a random name loses that race and leaves a file behind every
    // single time — hundreds had accumulated in ~/Library/Preferences. A stable
    // name still isolates (the domain is emptied on the way in) and can leave
    // at most one file. `forgetTestDefaults` clears it up, within the limits
    // set out on that method.
    private static let suiteName = "aloud-agent-settings"
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = Self.suiteName
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        forgetTestDefaults(suiteName)
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

    func testConsentModeDefaultsToOpen() {
        // Agents are let in on sight: the feature is already behind an explicit
        // opt-in, and the pill with its name badge is the disclosure. Asking
        // every time charged the first question of every session a round of
        // "yes" — the exact moment the feature exists to save.
        XCTAssertEqual(store().agentConsentMode, .open)
    }

    func testConsentModePersists() {
        let s = store()
        s.agentConsentMode = .confirmOnScreen
        XCTAssertEqual(SettingsStore(defaults: defaults).agentConsentMode, .confirmOnScreen)
    }

    // Settings shows two switches over the three modes. The mode stays the one
    // stored truth — these pin the mapping in both directions, since the bridge
    // reads the mode and never the switches.
    func testAskingSwitchesDriveTheMode() {
        let s = store()
        // Both switches start off, which is the shipped default.
        XCTAssertFalse(s.agentAsksFirst)
        XCTAssertFalse(s.agentAsksOutLoud)

        s.agentAsksFirst = true
        XCTAssertEqual(s.agentConsentMode, .confirmOnScreen)

        s.agentAsksOutLoud = true
        XCTAssertEqual(s.agentConsentMode, .confirmByVoice)

        s.agentAsksOutLoud = false
        XCTAssertEqual(s.agentConsentMode, .confirmOnScreen)

        s.agentAsksFirst = false
        XCTAssertEqual(s.agentConsentMode, .open)
        XCTAssertFalse(s.agentAsksFirst)
    }

    // Turning asking back on has to return the prompt the user picked, not the
    // default: a switch that quietly changes a second setting behind it is a
    // setting the user has to re-check every time.
    func testThePromptStyleSurvivesAskingBeingTurnedOff() {
        let s = store()
        s.agentAsksOutLoud = false
        s.agentAsksFirst = false
        XCTAssertEqual(s.agentConsentMode, .open)
        // Still remembered while nothing is being asked, and still remembered
        // by a store that reads it back off disk.
        XCTAssertFalse(s.agentAsksOutLoud)
        XCTAssertFalse(SettingsStore(defaults: defaults).agentAsksOutLoud)

        s.agentAsksFirst = true
        XCTAssertEqual(s.agentConsentMode, .confirmOnScreen)

        // And the whole cycle for the style that is not the default, which is
        // the one a user has to have gone out of their way to choose. Stopping
        // at "off" proves nothing: the interesting half is the way back on, and
        // it is the half that hands somebody the wrong prompt.
        s.agentAsksOutLoud = true
        XCTAssertEqual(s.agentConsentMode, .confirmByVoice)

        s.agentAsksFirst = false
        XCTAssertEqual(s.agentConsentMode, .open, "asking off is asking off, whatever the style")
        XCTAssertTrue(s.agentAsksOutLoud, "the choice is remembered, not cleared")
        XCTAssertTrue(SettingsStore(defaults: defaults).agentAsksOutLoud,
                      "and remembered on disk, not just in this object")

        s.agentAsksFirst = true
        XCTAssertEqual(s.agentConsentMode, .confirmByVoice,
                       "turning asking back on has to return the prompt they picked")
    }

    // Hands-free was a shipped toggle and this release took the control away.
    // The stored value still has to be honoured: somebody turned it off on
    // purpose — almost always because an accidental double-tap left the
    // microphone open — and handing that back on an update is the one outcome
    // the setting existed to prevent. Nobody who never touched it is affected.
    func testAHandsFreeChoiceFromAnEarlierVersionIsStillHonoured() {
        XCTAssertTrue(store().handsFree, "never chosen means on, as it always did")

        defaults.set(false, forKey: "handsFree")
        XCTAssertFalse(store().handsFree,
                       "a user who switched hands-free off must not get it back on an update")
    }

    // An install from before the two-switch pane has a mode and no switch: the
    // switch reads itself off the mode rather than snapping to the default.
    func testTheOutLoudSwitchIsReadBackOffAnExistingMode() {
        // The case that carries the whole test. `.confirmOnScreen` and `.open`
        // both expect false — which is what a plain default answers too, so
        // neither can tell a real read-back from `?? false`. Only an install
        // that was already asking *out loud* can: downgrading it to the
        // on-screen prompt is a setting silently undone by an update.
        defaults.set(AgentConsentMode.confirmByVoice.rawValue, forKey: "agentConsentMode")
        let outLoud = store()
        XCTAssertTrue(outLoud.agentAsksFirst)
        XCTAssertTrue(outLoud.agentAsksOutLoud,
                      "an install that was asking out loud must not be quietly put back on screen")

        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(AgentConsentMode.confirmOnScreen.rawValue, forKey: "agentConsentMode")
        XCTAssertFalse(store().agentAsksOutLoud)

        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(AgentConsentMode.open.rawValue, forKey: "agentConsentMode")
        let open = store()
        XCTAssertFalse(open.agentAsksFirst)
        // Open says nothing about how the question would be asked, and the
        // spoken prompt is no longer the default — so turning asking back on
        // gives the on-screen prompt until the user says otherwise.
        XCTAssertFalse(open.agentAsksOutLoud)
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
