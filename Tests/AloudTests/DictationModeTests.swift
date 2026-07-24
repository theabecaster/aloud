import XCTest
@testable import Aloud

final class DictationModeTests: XCTestCase {
    // MARK: built-in category resolution

    func testBuiltInTableResolvesKnownApps() {
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "com.apple.MobileSMS"), .messaging)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "com.tinyspeck.slackmacgap"), .messaging)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "com.hnc.Discord"), .messaging)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "ru.keepcoder.Telegram"), .messaging)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "net.whatsapp.WhatsApp"), .messaging)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "com.apple.mail"), .email)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "com.microsoft.Outlook"), .email)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "com.readdle.SparkDesktop"), .email)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "com.apple.Notes"), .notes)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "md.obsidian"), .notes)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "net.shinyfrog.bear"), .notes)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "notion.id"), .notes)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "com.apple.Terminal"), .code)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "com.googlecode.iterm2"), .code)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "com.mitchellh.ghostty"), .code)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "dev.warp.Warp-Stable"), .code)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "com.microsoft.VSCode"), .code)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "com.todesktop.230313mzl4w4u92"), .code)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "com.apple.dt.Xcode"), .code)
    }

    func testJetBrainsFamilyResolvesByPrefix() {
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "com.jetbrains.intellij"), .code)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "com.jetbrains.PyCharm"), .code)
        // The bare prefix owner shouldn't be a coincidence match elsewhere.
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "com.jetbrainsish.other"), .general)
    }

    func testUnknownAppsAreGeneral() {
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "com.example.someapp"), .general)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: ""), .general)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: nil), .general)
    }

    func testResolutionIgnoresBundleIDCase() {
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "COM.APPLE.MOBILESMS"), .messaging)
        XCTAssertEqual(DictationMode.builtIn(forBundleID: "com.apple.mobilesms"), .messaging)
    }

    // MARK: tone instruction selection

    func testToneInstructionsPerCategory() {
        XCTAssertNotNil(DictationMode.messaging.toneInstruction)
        XCTAssertNotNil(DictationMode.email.toneInstruction)
        XCTAssertNotNil(DictationMode.notes.toneInstruction)
        XCTAssertNil(DictationMode.general.toneInstruction)
        XCTAssertNil(DictationMode.code.toneInstruction)
        // Each tone is its own instruction, not a shared string.
        XCTAssertNotEqual(DictationMode.messaging.toneInstruction, DictationMode.email.toneInstruction)
        XCTAssertNotEqual(DictationMode.email.toneInstruction, DictationMode.notes.toneInstruction)
    }

    // MARK: verbatim safety for code apps

    func testCodeIsTheOnlyCategoryThatSkipsTheRewrite() {
        XCTAssertFalse(DictationMode.code.allowsRewrite)
        for mode in DictationMode.allCases where mode != .code {
            XCTAssertTrue(mode.allowsRewrite, "\(mode) should allow the rewrite")
        }
    }

    func testTerminalsAndEditorsResolveToNoRewrite() {
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                   "dev.warp.Warp-Stable", "com.microsoft.VSCode",
                   "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode",
                   "com.jetbrains.WebStorm"] {
            XCTAssertFalse(DictationMode.builtIn(forBundleID: id).allowsRewrite,
                           "\(id) must never be creatively rewritten")
        }
        XCTAssertTrue(DictationMode.builtIn(forBundleID: "com.example.someapp").allowsRewrite)
    }

    func testInstructionCombining() {
        XCTAssertEqual(EnhancerInstructions.combine("base", extra: nil), "base")
        XCTAssertEqual(EnhancerInstructions.combine("base", extra: "  "), "base")
        XCTAssertEqual(EnhancerInstructions.combine("base", extra: "tone line"),
                       "base\n\ntone line")
    }

    // MARK: custom rule precedence

    func testWithoutRulesTheBuiltInTableDecides() {
        let slack = ModeResolver.decision(forBundleID: "com.tinyspeck.slackmacgap", rules: [])
        XCTAssertTrue(slack.allowsRewrite)
        XCTAssertEqual(slack.extraInstructions, DictationMode.messaging.toneInstruction)
        let terminal = ModeResolver.decision(forBundleID: "com.apple.Terminal", rules: [])
        XCTAssertEqual(terminal, ModeDecision(allowsRewrite: false, extraInstructions: nil))
        let unknown = ModeResolver.decision(forBundleID: "com.example.someapp", rules: [])
        XCTAssertEqual(unknown, ModeDecision(allowsRewrite: true, extraInstructions: nil))
    }

    func testVerbatimRuleBeatsBuiltInCategory() {
        let rules = [AppModeRule(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                                 behavior: .verbatim)]
        let decision = ModeResolver.decision(forBundleID: "com.tinyspeck.slackmacgap", rules: rules)
        XCTAssertEqual(decision, ModeDecision(allowsRewrite: false, extraInstructions: nil))
        // Other apps are untouched by the rule.
        XCTAssertTrue(ModeResolver.decision(forBundleID: "com.apple.mail", rules: rules).allowsRewrite)
    }

    func testCategoryOverrideRuleBeatsBuiltInCategory() {
        // Slack pinned to the email tone — someone's workspace is formal.
        let rules = [AppModeRule(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                                 behavior: .category(.email))]
        let decision = ModeResolver.decision(forBundleID: "com.tinyspeck.slackmacgap", rules: rules)
        XCTAssertTrue(decision.allowsRewrite)
        XCTAssertEqual(decision.extraInstructions, DictationMode.email.toneInstruction)
        // A category override to code inherits its verbatim safety.
        let toCode = [AppModeRule(appName: nil, bundleID: "com.example.someapp",
                                  behavior: .category(.code))]
        XCTAssertFalse(ModeResolver.decision(forBundleID: "com.example.someapp", rules: toCode).allowsRewrite)
    }

    func testCustomInstructionRuleCarriesTheInstruction() {
        let rules = [AppModeRule(appName: nil, bundleID: "com.example.journal",
                                 behavior: .custom("  Warm and upbeat.  "))]
        let decision = ModeResolver.decision(forBundleID: "com.example.journal", rules: rules)
        XCTAssertEqual(decision, ModeDecision(allowsRewrite: true, extraInstructions: "Warm and upbeat."))
        // A whitespace-only instruction degrades to no extra instructions.
        let blank = [AppModeRule(appName: nil, bundleID: "com.example.journal",
                                 behavior: .custom("   "))]
        XCTAssertEqual(ModeResolver.decision(forBundleID: "com.example.journal", rules: blank),
                       ModeDecision(allowsRewrite: true, extraInstructions: nil))
    }

    func testRuleMatchingIgnoresBundleIDCase() {
        let rules = [AppModeRule(appName: nil, bundleID: "Com.Example.App", behavior: .verbatim)]
        XCTAssertFalse(ModeResolver.decision(forBundleID: "com.example.app", rules: rules).allowsRewrite)
    }

    // MARK: persistence

    func testAppModeRuleCodableRoundTrip() throws {
        let rules = [
            AppModeRule(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                        behavior: .category(.email)),
            AppModeRule(appName: nil, bundleID: "com.example.journal",
                        behavior: .custom("Warm and upbeat.")),
            AppModeRule(appName: "Terminal", bundleID: "com.apple.Terminal",
                        behavior: .verbatim),
        ]
        let data = try JSONEncoder().encode(rules)
        XCTAssertEqual(try JSONDecoder().decode([AppModeRule].self, from: data), rules)
    }

    // The on-disk shape is a contract: saved rules must keep decoding across
    // releases, so this pins the exact JSON rather than just a round-trip.
    func testAppModeRuleDecodesTheStableWireFormat() throws {
        let json = """
        [{"id":"0A0B0C0D-0000-0000-0000-000000000001","appName":"Slack",
          "bundleID":"com.tinyspeck.slackmacgap","behavior":{"kind":"category","category":"messaging"}},
         {"id":"0A0B0C0D-0000-0000-0000-000000000002",
          "bundleID":"com.example.journal","behavior":{"kind":"custom","instruction":"Warm."}},
         {"id":"0A0B0C0D-0000-0000-0000-000000000003","appName":"Terminal",
          "bundleID":"com.apple.Terminal","behavior":{"kind":"verbatim"}}]
        """
        let rules = try JSONDecoder().decode([AppModeRule].self, from: Data(json.utf8))
        XCTAssertEqual(rules.count, 3)
        XCTAssertEqual(rules[0].behavior, .category(.messaging))
        XCTAssertNil(rules[1].appName)
        XCTAssertEqual(rules[1].behavior, .custom("Warm."))
        XCTAssertEqual(rules[2].behavior, .verbatim)
    }
}
