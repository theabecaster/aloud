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
}
