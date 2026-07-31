import XCTest
import Carbon.HIToolbox
@testable import Aloud

// The old default — a lone left ⌥ — still drives the single-modifier engine
// tests; the shipping default is now the ⌃⌥ chord, covered by HotkeyChordTests.
private let loneOption = Hotkey(keyCode: UInt16(kVK_Option), modifiers: 0, isModifierKey: true)

final class HotkeyNameTests: XCTestCase {
    // Regression: a saved hotkey on a plain letter key (e.g. X, keyCode 7) crashed
    // keyName(for:) via an invalid F-key range pattern, killing the menu on open.
    func testKeyNameNeverTrapsForAnyKeyCode() {
        for code in UInt16(0)...UInt16(255) {
            XCTAssertFalse(Hotkey.keyName(for: code).isEmpty)
        }
    }

    func testKnownKeyNames() {
        XCTAssertEqual(Hotkey.keyName(for: UInt16(kVK_F1)), "F1")
        XCTAssertEqual(Hotkey.keyName(for: UInt16(kVK_F20)), "F20")
        XCTAssertEqual(Hotkey.keyName(for: UInt16(kVK_RightOption)), "Right ⌥")
        XCTAssertEqual(Hotkey.keyName(for: UInt16(kVK_ANSI_X)), "X")
        XCTAssertFalse(Hotkey(keyCode: UInt16(kVK_ANSI_X), modifiers: 0, isModifierKey: false).displayName.isEmpty)
    }
}

final class HotkeyEngineTests: XCTestCase {
    private let key = loneOption.keyCode
    private let flag = loneOption.modifierFlag!

    func testModifierHoldCommit() {
        var engine = HotkeyEngine(hotkey: loneOption)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0), .begin)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 1.0), .commit)
    }

    func testShortTapCancels() {
        var engine = HotkeyEngine(hotkey: loneOption)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0), .begin)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.05), .cancel)
    }

    func testEscCancelsWhileHeld() {
        var engine = HotkeyEngine(hotkey: loneOption)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0)
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 53, flags: flag, time: 0.3), .cancel)
        // A later release must not double-fire.
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.5), .none)
    }

    func testOtherModifierIgnored() {
        var engine = HotkeyEngine(hotkey: loneOption)
        // Right ⌥ (61) toggles the same flag as the default left ⌥ but is a different key.
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: 61, flags: .maskAlternate, time: 0), .none)
    }

    func testResetClearsLockAndAllowsFreshHold() {
        var engine = HotkeyEngine(hotkey: loneOption)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.05)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0.2)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.25), .lock)
        engine.reset()
        XCTAssertFalse(engine.isLocked)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 1.0), .begin)
    }

    func testDoublePressLocksUntilEsc() {
        var engine = HotkeyEngine(hotkey: loneOption)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.05), .cancel)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0.2)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.25), .lock)
        // Hotkey presses of any length are ignored while locked.
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 1.0)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 1.8), .none)
        // Esc finishes and commits the hands-free session.
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 53, flags: [], time: 2.0), .commit)
        XCTAssertFalse(engine.isLocked)
    }

    func testDoubleTapStopsHandsFree() {
        var engine = HotkeyEngine(hotkey: loneOption)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.05)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0.2)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.25), .lock)
        // Double-tapping the hotkey again finishes and commits the session.
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 1.0), .none)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 1.05), .none)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 1.2), .commit)
        XCTAssertFalse(engine.isLocked)
        // The stopping tap's release is swallowed — no cancel, no new session.
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 1.25), .none)
        // A fresh press afterwards starts a normal hold, not hands-free.
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 2.0), .begin)
        XCTAssertFalse(engine.isLocked)
    }

    func testSlowTapsDoNotLock() {
        var engine = HotkeyEngine(hotkey: loneOption)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.05), .cancel)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 1.0)   // outside window
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 1.05), .cancel)
        XCTAssertFalse(engine.isLocked)
    }

    func testSlowTapsWhileLockedStayLocked() {
        var engine = HotkeyEngine(hotkey: loneOption)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.05)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0.2)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.25), .lock)
        // Presses further apart than the double-tap window do nothing.
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 1.0)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 1.05)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 2.0), .none)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 2.05), .none)
        XCTAssertTrue(engine.isLocked)
        // Esc still works as before.
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 53, flags: [], time: 3.0), .commit)
    }

    func testHandsFreeDisabled() {
        var engine = HotkeyEngine(hotkey: loneOption, handsFreeEnabled: false)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.05)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0.2)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.25), .cancel)
        XCTAssertFalse(engine.isLocked)
    }

    func testRegularKeyHotkey() {
        var engine = HotkeyEngine(hotkey: Hotkey(keyCode: 96, modifiers: 0, isModifierKey: false))
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 96, flags: [], time: 0), .begin)
        XCTAssertEqual(engine.handle(type: .keyUp, keyCode: 96, flags: [], time: 0.5), .commit)
    }

    func testHotkeyCodableRoundTrip() throws {
        let hk = Hotkey(keyCode: 96, modifiers: CGEventFlags.maskCommand.rawValue, isModifierKey: false)
        let decoded = try JSONDecoder().decode(Hotkey.self, from: JSONEncoder().encode(hk))
        XCTAssertEqual(decoded, hk)
    }

    func testHotkeyDecodesLegacyPayloadWithoutMouseField() throws {
        // Persisted before isMouseButton existed — must decode, not reset to default.
        let legacy = Data(#"{"keyCode":58,"modifiers":0,"isModifierKey":true}"#.utf8)
        let decoded = try JSONDecoder().decode(Hotkey.self, from: legacy)
        XCTAssertEqual(decoded, loneOption)
        XCTAssertFalse(decoded.isMouseButton)
        XCTAssertFalse(decoded.isChord)
    }

    func testMouseButtonHotkeyHoldCommit() {
        var engine = HotkeyEngine(hotkey: Hotkey(keyCode: 3, modifiers: 0,
                                                 isModifierKey: false, isMouseButton: true))
        XCTAssertEqual(engine.handle(type: .otherMouseDown, keyCode: 3, flags: [], time: 0), .begin)
        XCTAssertEqual(engine.handle(type: .otherMouseUp, keyCode: 3, flags: [], time: 0.5), .commit)
        // A keyboard key with the same code must not trigger a mouse hotkey.
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 3, flags: [], time: 1.0), .none)
    }

    func testMouseButtonIgnoredForKeyboardHotkey() {
        var engine = HotkeyEngine(hotkey: Hotkey(keyCode: 3, modifiers: 0, isModifierKey: false))
        XCTAssertEqual(engine.handle(type: .otherMouseDown, keyCode: 3, flags: [], time: 0), .none)
    }

    func testEnhancerOutputValidation() {
        let original = "We should move the launch back a week because testing is not done."
        // Good rewrite passes through trimmed.
        XCTAssertEqual(EnhancerOutputCheck.validate("  Move the launch back a week.  ", original: original),
                       "Move the launch back a week.")
        // The observed failure modes are all rejected.
        XCTAssertNil(EnhancerOutputCheck.validate("", original: original))
        XCTAssertNil(EnhancerOutputCheck.validate("```swift\nfunc x() {}\n```", original: original))
        XCTAssertNil(EnhancerOutputCheck.validate(String(repeating: "padding ", count: 60), original: original))
        XCTAssertNil(EnhancerOutputCheck.validate("I cannot rewrite the text as requested.", original: original))
        XCTAssertNil(EnhancerOutputCheck.validate("I'm sorry, but I can't help with that.", original: original))
        // A transcript that merely starts with "I can't" in the speaker's own
        // voice is longer than a refusal and must survive — prefix match only
        // rejects, it never rewrites, so the fallback keeps the polished text.
        XCTAssertNotNil(EnhancerOutputCheck.validate(
            "It cannot ship this week.", original: "um it cannot ship this week testing is not done"))
    }

    @MainActor
    func testContextHintBuiltFromFieldText() {
        XCTAssertNil(DictationController.contextHint(from: nil))
        XCTAssertNil(DictationController.contextHint(from: FocusSnapshot(appName: "X", appBundleID: "x")))
        var snap = FocusSnapshot(appName: "Mail", appBundleID: "com.apple.mail")
        snap.fieldText = "Hi Chellie — following up on the Smyth contract."
        let hint = DictationController.contextHint(from: snap)
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("Chellie"))
        // Long fields keep only the tail near the cursor.
        snap.fieldText = String(repeating: "a", count: 1000) + " Chellie"
        XCTAssertLessThan(DictationController.contextHint(from: snap)!.count, 450)
    }

    func testGeneratedChatRepliesAreRejected() {
        XCTAssertNil(CommandOutputCheck.validateGenerated("Sure! What can I do for you?"))
        XCTAssertNil(CommandOutputCheck.validateGenerated("¡Claro! ¿Qué puedo hacer por ti?"))
        XCTAssertNil(CommandOutputCheck.validateGenerated("I'd be happy to help with that."))
        XCTAssertNil(CommandOutputCheck.validateGenerated(""))
        // Real insertions still pass, including ones that begin with I.
        XCTAssertEqual(CommandOutputCheck.validateGenerated("I'm back Monday."), "I'm back Monday.")
        XCTAssertEqual(CommandOutputCheck.validateGenerated("\u{201C}Buongiorno!\u{201D}"), "Buongiorno!")
    }

    func testRoleFlippedRequestsAreRejected() {
        let request = "Hey can you send me the report when you get a chance"
        XCTAssertNil(EnhancerOutputCheck.validate("Sure, I'll send it when I get a chance.", original: request))
        XCTAssertNil(EnhancerOutputCheck.validate("I'll send it over shortly.", original: request))
        // The request kept as a request passes.
        XCTAssertNotNil(EnhancerOutputCheck.validate("Hey, can you send me the report when you get a chance?",
                                                     original: request))
        // First-person statements aren't requests — "I'll" outputs are fine.
        XCTAssertNotNil(EnhancerOutputCheck.validate("I'll send the invoice tomorrow.",
                                                     original: "um I'll send the invoice tomorrow"))
    }

    // Observed: a reply that also asks a question back used to pass, because
    // the old net only fired when the output contained no question of its own.
    func testAssistantReplyWithCounterQuestionIsRejected() {
        let request = "can you please send me an email to my email"
        XCTAssertNil(EnhancerOutputCheck.validate(
            "Sure, I can help you with that. Could you please provide me with the details of the email you want to send?",
            original: request))
        // Same shape, other openers.
        XCTAssertNil(EnhancerOutputCheck.validate("Of course! What would you like it to say?", original: request))
        XCTAssertNil(EnhancerOutputCheck.validate("Happy to help — could you share the address?", original: request))
        XCTAssertNil(EnhancerOutputCheck.validate("Got it. I'll draft that for you.", original: request))
        // The request kept as a request still passes.
        XCTAssertNotNil(EnhancerOutputCheck.validate("Can you please send me an email?", original: request))
    }

    // A speaker who really did open with "Sure" keeps their words: the opener
    // only convicts when it appeared out of nowhere.
    func testSpeakersOwnReplyOpenerSurvives() {
        XCTAssertNotNil(EnhancerOutputCheck.validate(
            "Sure, I'll send it tonight.", original: "um sure I'll send it tonight"))
        XCTAssertNotNil(EnhancerOutputCheck.validate(
            "Of course, that works for me.", original: "of course uh that works for me"))
    }

    // Observed live in Ghostty: the model answered the dictated question,
    // rebuilding it from the question's own words — short enough to pass the
    // length net, overlapping enough to pass the content-word net, and opening
    // with none of the listed reply openers.
    func testAnsweredQuestionIsRejected() {
        let question = "In the Mac menu what do I have to type into the terminal to see the logs or the tmux or whatever session?"
        XCTAssertNil(EnhancerOutputCheck.validate(
            "To see the logs or the tmux session, you need to type `tman` into the terminal.",
            original: question))
        // The question kept as a question passes.
        XCTAssertNotNil(EnhancerOutputCheck.validate(
            "What do I have to type into the terminal to see the tmux session?",
            original: question))
        // A wh-question the ASR left without a "?" still convicts its answer.
        XCTAssertNil(EnhancerOutputCheck.validate(
            "The logs go in the terminal.", original: "um where do the logs go"))
        // Contracted wh-openers and leading discourse words don't hide one.
        XCTAssertNil(EnhancerOutputCheck.validate(
            "Paris is the capital of France.", original: "so what's the capital of France is it Paris"))
    }

    // Observed live: the speaker's "three main topics. First… then… finally…"
    // came back flattened into a plain clause list — summarized, not tightened.
    func testDroppedEnumerationStructureIsRejected() {
        let original = "We need to cover three main topics. First the quarterly budget, then hiring plan, and finally the roadmap."
        XCTAssertNil(EnhancerOutputCheck.validate(
            "We need to cover the quarterly budget, the hiring plan, and the roadmap.",
            original: original))
        // Keeping the structure passes…
        XCTAssertNotNil(EnhancerOutputCheck.validate(
            "We need to cover three main topics. First the quarterly budget, then hiring plan, and finally the roadmap.",
            original: original))
        // …and so does restructuring into an actual list.
        XCTAssertNotNil(EnhancerOutputCheck.validate(
            "We need to cover three main topics:\n- Quarterly budget\n- Hiring plan\n- Roadmap",
            original: original))
        // One lone "then" is not an enumeration; tightening it away is fine.
        XCTAssertNotNil(EnhancerOutputCheck.validate(
            "Grab the keys and lock up.", original: "um grab the keys and then lock up"))
    }

    // The transcript is sent inside <TRANSCRIPT> tags; a model that echoes
    // them back around an otherwise good rewrite is unwrapped, not rejected.
    func testEchoedTranscriptTagsAreUnwrapped() {
        XCTAssertEqual(EnhancerOutputCheck.validate(
            "<TRANSCRIPT>\nMove the launch back a week.\n</TRANSCRIPT>",
            original: "We should move the launch back a week because testing is not done."),
            "Move the launch back a week.")
    }

    // The other face of the same failure: the rewrite addresses a "you" the
    // speaker never spoke to.
    func testSecondPersonFromNowhereIsRejected() {
        XCTAssertNil(EnhancerOutputCheck.validate(
            "You should check the printer before the meeting.",
            original: "um I should check the printer uh before the meeting"))
        // A "you" the speaker actually said survives.
        XCTAssertNotNil(EnhancerOutputCheck.validate(
            "Can you check the printer before the meeting?",
            original: "um can you check the printer uh before the meeting"))
    }

    // Observed live: "insert my email" came back as example #3 from the
    // model's own instructions — words the speaker never said.
    func testEchoedInstructionExamplesAreRejected() {
        for example in EnhancerOutputCheck.exampleOutputs {
            XCTAssertNil(EnhancerOutputCheck.validate(example, original: "insert my email"),
                         "echoed example slipped through: \(example)")
        }
        // Also when the model wraps it in something else.
        XCTAssertNil(EnhancerOutputCheck.validate(
            "Sounds good. Let's leave at nine thirty.", original: "insert my email"))
    }

    // The catch-all: a rewrite made mostly of words the speaker never said.
    func testComposedTextIsRejected() {
        XCTAssertNil(EnhancerOutputCheck.validate(
            "I have not received your email regarding the contract. Please let me know when you can send it.",
            original: "Hey just wanted to check if you got my last email about the contract. Lemme know when you can."))
        // A genuine tightening keeps the speaker's words and passes.
        XCTAssertNotNil(EnhancerOutputCheck.validate(
            "I was thinking we could maybe push the meeting to Thursday because the deck isn't ready yet.",
            original: "Um so I was thinking we could uh maybe push the meeting to Thursday because um the deck isn't ready yet."))
    }

    // Nothing to tighten: ship the polished transcript, don't wake the model.
    func testShortTranscriptsSkipTheRewrite() {
        XCTAssertFalse(EnhancerOutputCheck.isWorthRewriting("insert my email"))
        XCTAssertFalse(EnhancerOutputCheck.isWorthRewriting("send it"))
        XCTAssertTrue(EnhancerOutputCheck.isWorthRewriting("can you send me the report today"))
    }

    // The rejection list has to stay in step with the prompt it mirrors.
    func testExampleOutputsMatchTheInstructions() throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw XCTSkip("no system language model") }
        for example in EnhancerOutputCheck.exampleOutputs {
            XCTAssertTrue(FoundationModelEnhancer.instructions.contains(example),
                          "example drifted out of the instructions: \(example)")
        }
        #endif
    }

    // A short line can gain punctuation, not a paragraph.
    func testShortTranscriptCannotBalloon() {
        let short = "send the invoice"
        XCTAssertNotNil(EnhancerOutputCheck.validate("Send the invoice.", original: short))
        XCTAssertNil(EnhancerOutputCheck.validate(
            "Please send the invoice to the client as soon as you get a chance today.", original: short))
    }

    func testConciseKeepsSpokenCorrectionsForTheRewrite() {
        var p = TextPolisher(level: .standard, replacements: [])
        p.spokenCorrections = false
        // "no wait" survives for the rewrite engine to resolve with full context…
        XCTAssertTrue(p.polish("meet at 2 no wait 3").contains("no wait"))
        // …while the default deterministic path still applies it.
        XCTAssertFalse(TextPolisher(level: .standard, replacements: [])
            .polish("meet at 2 no wait 3").contains("no wait"))
    }

    func testConciseFallsBackToStandardRules() {
        XCTAssertEqual(PolishLevel.concise.deterministicLevel, .standard)
        XCTAssertEqual(PolishLevel.standard.deterministicLevel, .standard)
        XCTAssertEqual(PolishLevel.off.deterministicLevel, .off)
    }

    func testHistorySearchMatching() {
        let entry = HistoryEntry(text: "Review the pull request",
                                 rawText: "review the the pull request",
                                 duration: 3, appName: "Slack", appBundleID: "com.tinyspeck.slackmacgap")
        XCTAssertTrue(entry.matches("PULL"))
        XCTAssertTrue(entry.matches("the the"))   // raw transcript is searchable
        XCTAssertTrue(entry.matches("slack"))     // so is the app name
        XCTAssertFalse(entry.matches("zoom"))
    }

    func testTrailingPressEnterStripped() {
        XCTAssertEqual(TrailingCommand.stripPressEnter("Sounds good, press enter"), "Sounds good")
        XCTAssertEqual(TrailingCommand.stripPressEnter("Ship it and press enter."), "Ship it")
        XCTAssertEqual(TrailingCommand.stripPressEnter("Done, then press return"), "Done")
        XCTAssertEqual(TrailingCommand.stripPressEnter("Press Enter"), "")
    }

    func testMidSentencePressEnterIgnored() {
        XCTAssertNil(TrailingCommand.stripPressEnter("You press enter to submit the form"))
        XCTAssertNil(TrailingCommand.stripPressEnter("The presenter was great"))
        XCTAssertNil(TrailingCommand.stripPressEnter("Just some normal text"))
    }

    func testAudioBackupRoundTrip() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples: [Float] = (0..<8000).map { sin(Float($0) * 0.01) }
        AudioBackup.save(samples: samples, to: url)
        let loaded = AudioBackup.load(from: url)
        XCTAssertEqual(loaded?.count, samples.count)
        XCTAssertEqual(loaded?[1234] ?? -1, samples[1234], accuracy: 0.0001)
    }

    func testForceLockBehavesLikeHandsFreeSession() {
        var engine = HotkeyEngine(hotkey: loneOption)
        engine.forceLock()
        XCTAssertTrue(engine.isLocked)
        // Esc finishes and commits, exactly like a double-tap lock.
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 53, flags: [], time: 1.0), .commit)
        XCTAssertFalse(engine.isLocked)
    }
}

final class CommandKeyEngineTests: XCTestCase {
    private let key = loneOption.keyCode
    private let flag = loneOption.modifierFlag!

    func testHoldCommitsCommand() {
        var engine = CommandKeyEngine(hotkey: loneOption)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0), .beginCommand)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 1.0), .commitCommand)
    }

    func testShortTapCancelsCommand() {
        var engine = CommandKeyEngine(hotkey: loneOption)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0), .beginCommand)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.05), .cancelCommand)
    }

    func testEscCancelsCommandHold() {
        var engine = CommandKeyEngine(hotkey: loneOption)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0)
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 53, flags: flag, time: 0.3), .cancelCommand)
        // The eventual release must not double-fire.
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.5), .none)
    }

    func testDoubleTapNeverLocks() {
        // A command is one held utterance — no hands-free variant, ever.
        var engine = CommandKeyEngine(hotkey: loneOption)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.05)
        _ = engine.handle(type: .flagsChanged, keyCode: key, flags: flag, time: 0.2)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: key, flags: [], time: 0.25), .cancelCommand)
    }

    func testOtherKeysFallThrough() {
        // .none = not consumed: the manager falls through to the main engine.
        var engine = CommandKeyEngine(hotkey: Hotkey(keyCode: 96, modifiers: 0, isModifierKey: false))
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 97, flags: [], time: 0), .none)
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 53, flags: [], time: 0.1), .none)
    }

    func testRegularKeyCommandHotkey() {
        var engine = CommandKeyEngine(hotkey: Hotkey(keyCode: 96, modifiers: 0, isModifierKey: false))
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 96, flags: [], time: 0), .beginCommand)
        XCTAssertEqual(engine.handle(type: .keyUp, keyCode: 96, flags: [], time: 0.5), .commitCommand)
    }
}

final class HotkeyChordTests: XCTestCase {
    private let ctrl = UInt16(kVK_Control)
    private let opt = UInt16(kVK_Option)
    private let cmd = UInt16(kVK_Command)
    private let chord = Hotkey.default   // ⌃⌥

    func testChordHoldCommit() {
        var engine = HotkeyEngine(hotkey: chord)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: ctrl, flags: .maskControl, time: 0), .none)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: opt,
                                     flags: [.maskControl, .maskAlternate], time: 0.05), .begin)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: opt, flags: .maskControl, time: 0.6), .commit)
        // The trailing release of the other member stays quiet.
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: ctrl, flags: [], time: 0.65), .none)
    }

    func testChordIsSideInsensitive() {
        var engine = HotkeyEngine(hotkey: chord)
        // Right ⌃ + right ⌥ raise the same mask bits.
        _ = engine.handle(type: .flagsChanged, keyCode: UInt16(kVK_RightControl), flags: .maskControl, time: 0)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: UInt16(kVK_RightOption),
                                     flags: [.maskControl, .maskAlternate], time: 0.05), .begin)
    }

    func testChordReachedByReleasingNeverBegins() {
        var engine = HotkeyEngine(hotkey: chord)
        _ = engine.handle(type: .flagsChanged, keyCode: ctrl, flags: .maskControl, time: 0)
        _ = engine.handle(type: .flagsChanged, keyCode: cmd, flags: [.maskControl, .maskCommand], time: 0.02)
        // ⌃⌥⌘ down in a superset order, then ⌘ released → exactly ⌃⌥, but by release.
        _ = engine.handle(type: .flagsChanged, keyCode: opt,
                          flags: [.maskControl, .maskCommand, .maskAlternate], time: 0.04)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: cmd,
                                     flags: [.maskControl, .maskAlternate], time: 0.5), .none)
    }

    func testForeignKeyInGraceWindowCancels() {
        var engine = HotkeyEngine(hotkey: chord)
        _ = engine.handle(type: .flagsChanged, keyCode: ctrl, flags: .maskControl, time: 0)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: opt,
                                     flags: [.maskControl, .maskAlternate], time: 0.05), .begin)
        // ⌃⌥← half a beat later: that was a window-snap shortcut, not speech.
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 123,
                                     flags: [.maskControl, .maskAlternate], time: 0.2), .cancel)
        // The eventual chord release must not commit the dead session.
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: opt, flags: .maskControl, time: 0.5), .none)
        // And a fresh press right after works again.
        _ = engine.handle(type: .flagsChanged, keyCode: ctrl, flags: [], time: 0.55)
        _ = engine.handle(type: .flagsChanged, keyCode: ctrl, flags: .maskControl, time: 1.0)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: opt,
                                     flags: [.maskControl, .maskAlternate], time: 1.05), .begin)
    }

    func testStrayKeyAfterGraceWindowIgnored() {
        var engine = HotkeyEngine(hotkey: chord)
        _ = engine.handle(type: .flagsChanged, keyCode: ctrl, flags: .maskControl, time: 0)
        _ = engine.handle(type: .flagsChanged, keyCode: opt, flags: [.maskControl, .maskAlternate], time: 0.05)
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 11,
                                     flags: [.maskControl, .maskAlternate], time: 2.0), .none)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: opt, flags: .maskControl, time: 3.0), .commit)
    }

    func testForeignKeyCancelAppliesToLoneModifierToo() {
        // The today-bug this fixes: lone-⌥ users word-jumping with ⌥← left a
        // phantom recording running.
        var engine = HotkeyEngine(hotkey: loneOption)
        _ = engine.handle(type: .flagsChanged, keyCode: loneOption.keyCode, flags: .maskAlternate, time: 0)
        XCTAssertEqual(engine.handle(type: .keyDown, keyCode: 123, flags: .maskAlternate, time: 0.15), .cancel)
    }

    func testChordDoubleTapLocksHandsFree() {
        var engine = HotkeyEngine(hotkey: chord)
        _ = engine.handle(type: .flagsChanged, keyCode: ctrl, flags: .maskControl, time: 0)
        _ = engine.handle(type: .flagsChanged, keyCode: opt, flags: [.maskControl, .maskAlternate], time: 0.02)
        _ = engine.handle(type: .flagsChanged, keyCode: opt, flags: .maskControl, time: 0.06)
        _ = engine.handle(type: .flagsChanged, keyCode: opt, flags: [.maskControl, .maskAlternate], time: 0.2)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: opt, flags: .maskControl, time: 0.25), .lock)
        XCTAssertTrue(engine.isLocked)
    }

    func testExtraModifierInGraceWindowCancels() {
        var engine = HotkeyEngine(hotkey: chord)
        _ = engine.handle(type: .flagsChanged, keyCode: ctrl, flags: .maskControl, time: 0)
        _ = engine.handle(type: .flagsChanged, keyCode: opt, flags: [.maskControl, .maskAlternate], time: 0.05)
        XCTAssertEqual(engine.handle(type: .flagsChanged, keyCode: cmd,
                                     flags: [.maskControl, .maskAlternate, .maskCommand], time: 0.2), .cancel)
    }

    func testOverlapRules() {
        let cc = Hotkey.chord([.maskControl, .maskAlternate, .maskCommand])
        XCTAssertTrue(chord.overlaps(cc), "⌃⌥ inside ⌃⌥⌘")
        XCTAssertTrue(cc.overlaps(chord), "containment refused both directions")
        XCTAssertFalse(chord.overlaps(Hotkey.defaultHandsFreeKey), "⌃⌥ and ⌃⇧ coexist")
        XCTAssertFalse(chord.overlaps(Hotkey.defaultCommandKey), "⌃⌥ and ⌃⌘ coexist")
        XCTAssertFalse(Hotkey.defaultHandsFreeKey.overlaps(Hotkey.defaultCommandKey), "⌃⇧ and ⌃⌘ coexist")
        XCTAssertTrue(loneOption.overlaps(chord), "lone ⌥ inside ⌃⌥")
        XCTAssertFalse(loneOption.overlaps(
            Hotkey(keyCode: UInt16(kVK_RightOption), modifiers: 0, isModifierKey: true)),
            "left ⌥ and right ⌥ are different keys")
        let cmdSpace = Hotkey(keyCode: 49, modifiers: CGEventFlags.maskCommand.rawValue, isModifierKey: false)
        XCTAssertTrue(cmdSpace.overlaps(Hotkey(keyCode: UInt16(kVK_Command), modifiers: 0, isModifierKey: true)),
                      "lone ⌘ inside ⌘Space")
        let cmdShift = Hotkey.chord([.maskCommand, .maskShift])
        XCTAssertFalse(cmdShift.overlaps(cmdSpace), "⌘⇧ and ⌘Space share ⌘ but coexist")
        XCTAssertTrue(Hotkey.chord([.maskCommand, .maskShift, .maskAlternate]).overlaps(cmdShift))
    }

    func testChordDisplayNameAndCanonicalEquality() {
        XCTAssertEqual(chord.displayName, "⌃⌥")
        XCTAssertEqual(Hotkey.chord([.maskCommand, .maskShift, .maskControl]).displayName, "⌃⇧⌘")
        XCTAssertEqual(Hotkey.chord([.maskAlternate, .maskControl]), chord, "member order never matters")
        let mouse = Hotkey(keyCode: 3, modifiers: CGEventFlags.maskAlternate.rawValue,
                           isModifierKey: false, isMouseButton: true)
        XCTAssertTrue(mouse.displayName.hasPrefix("⌥ "))
    }

    func testChordCodableRoundTrip() throws {
        let decoded = try JSONDecoder().decode(Hotkey.self, from: JSONEncoder().encode(chord))
        XCTAssertEqual(decoded, chord)
        XCTAssertTrue(decoded.isChord)
    }

    func testMemberCounts() {
        XCTAssertEqual(loneOption.memberCount, 1)
        XCTAssertEqual(chord.memberCount, 2)
        XCTAssertEqual(Hotkey.chord([.maskControl, .maskAlternate, .maskCommand]).memberCount, 3)
        XCTAssertEqual(Hotkey(keyCode: 49, modifiers: CGEventFlags.maskCommand.rawValue,
                              isModifierKey: false).memberCount, 2)
        XCTAssertEqual(Hotkey(keyCode: 3, modifiers: 0, isModifierKey: false, isMouseButton: true).memberCount, 1)
    }

    func testMouseHotkeyWithModifierNeedsThatModifier() {
        let hk = Hotkey(keyCode: 3, modifiers: CGEventFlags.maskAlternate.rawValue,
                        isModifierKey: false, isMouseButton: true)
        var engine = HotkeyEngine(hotkey: hk)
        XCTAssertEqual(engine.handle(type: .otherMouseDown, keyCode: 3, flags: [], time: 0), .none)
        XCTAssertEqual(engine.handle(type: .otherMouseDown, keyCode: 3, flags: .maskAlternate, time: 1), .begin)
        XCTAssertEqual(engine.handle(type: .otherMouseUp, keyCode: 3, flags: .maskAlternate, time: 1.5), .commit)
    }
}

final class CommandIntentTests: XCTestCase {
    func testRoutingFollowsSelection() {
        // A selection means edit-in-place, whatever the parsed action said;
        // no selection means write at the cursor.
        let rewrite = CommandIntent(action: .rewrite, instruction: "make it shorter")
        XCTAssertEqual(rewrite.route(hasSelection: true), .rewrite)
        XCTAssertEqual(rewrite.route(hasSelection: false), .generate)
        let generate = CommandIntent(action: .generate, instruction: "write a thank-you note")
        XCTAssertEqual(generate.route(hasSelection: true), .rewrite)
        XCTAssertEqual(generate.route(hasSelection: false), .generate)
    }

    func testTranslateRouting() {
        let translate = CommandIntent(action: .translate, instruction: "translate this to Spanish",
                                      language: "Spanish")
        XCTAssertEqual(translate.route(hasSelection: true), .translate("Spanish"))
        XCTAssertEqual(translate.route(hasSelection: false), .generate)
        // No parsed target language → an ordinary rewrite; the instruction
        // still carries the intent.
        let vague = CommandIntent(action: .translate, instruction: "put this in French")
        XCTAssertEqual(vague.route(hasSelection: true), .rewrite)
    }

    func testConversationalRestatementFallsBackToSpokenWords() {
        // Spoken words are always the instruction; translate only sticks when
        // the words actually mention it.
        let plain = CommandIntent.resolved(action: .rewrite, language: nil, spoken: "make this all one line")
        XCTAssertEqual(plain, CommandIntent(action: .rewrite, instruction: "make this all one line"))
        let hallucinated = CommandIntent.resolved(action: .translate, language: "Spanish",
                                                  spoken: "purple monkey dishwasher")
        XCTAssertEqual(hallucinated, CommandIntent(action: .rewrite, instruction: "purple monkey dishwasher"))
        let byName = CommandIntent.resolved(action: .translate, language: "Spanish",
                                            spoken: "say this in spanish")
        XCTAssertEqual(byName, CommandIntent(action: .translate, instruction: "say this in spanish",
                                             language: "Spanish"))
        let byVerb = CommandIntent.resolved(action: .translate, language: "French",
                                            spoken: "translate this to french please")
        XCTAssertEqual(byVerb.action, .translate)
    }

    func testLanguageResolver() {
        XCTAssertEqual(LanguageResolver.language(named: "Spanish")?.languageCode?.identifier, "es")
        XCTAssertEqual(LanguageResolver.language(named: " german ")?.languageCode?.identifier, "de")
        XCTAssertEqual(LanguageResolver.language(named: "JAPANESE")?.languageCode?.identifier, "ja")
        // (Not "Klingon" — ICU genuinely knows it as tlh.)
        XCTAssertNil(LanguageResolver.language(named: "Wingdings"))
        XCTAssertNil(LanguageResolver.language(named: ""))
    }

    func testGeneratedOutputValidation() {
        XCTAssertEqual(CommandOutputCheck.validateGenerated("  Thanks for the update!  "),
                       "Thanks for the update!")
        // Whole-output quoting is unwrapped; interior quotes are left alone.
        XCTAssertEqual(CommandOutputCheck.validateGenerated("\"I'm back Monday.\""),
                       "I'm back Monday.")
        XCTAssertEqual(CommandOutputCheck.validateGenerated("“Back Monday.”"), "Back Monday.")
        XCTAssertEqual(CommandOutputCheck.validateGenerated("She said \"hi\" and \"bye\""),
                       "She said \"hi\" and \"bye\"")
        XCTAssertNil(CommandOutputCheck.validateGenerated(""))
        XCTAssertNil(CommandOutputCheck.validateGenerated("```swift\nfunc x() {}\n```"))
        XCTAssertNil(CommandOutputCheck.validateGenerated(String(repeating: "padding ", count: 200)))
    }
}

final class UpdaterTests: XCTestCase {
    func testSemver() {
        XCTAssertTrue(Updater.semverLess("1.0.0", "1.0.1"))
        XCTAssertTrue(Updater.semverLess("v1.9.0", "v1.10.0"))
        XCTAssertFalse(Updater.semverLess("2.0.0", "1.9.9"))
        XCTAssertFalse(Updater.semverLess("1.2.3", "1.2.3"))
        XCTAssertTrue(Updater.semverLess("1.2", "1.2.1"))
    }
}

final class HistoryStoreTests: XCTestCase {
    func testAppendLimitAndPersistence() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.json")

        let store = HistoryStore(fileURL: url)
        for i in 0..<8 { store.append(HistoryEntry(text: "entry \(i)", duration: 0.5), limit: 5) }
        XCTAssertEqual(store.entries.count, 5)
        XCTAssertEqual(store.entries.first?.text, "entry 7")

        // async persist
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 0.2)
        let reloaded = HistoryStore(fileURL: url)
        XCTAssertEqual(reloaded.entries.count, 5)
    }
}

final class LanguageDetectionTests: XCTestCase {
    func testDetectsClearLanguages() {
        XCTAssertEqual(LanguageDetection.code(
            for: "Please send the quarterly report to the whole team before Friday."), "en")
        XCTAssertEqual(LanguageDetection.code(
            for: "Por favor envía el informe trimestral a todo el equipo antes del viernes."), "es")
    }

    func testShortTextNeverGuessed() {
        XCTAssertNil(LanguageDetection.code(for: "ok"))
        XCTAssertNil(LanguageDetection.code(for: "   "))
    }

    func testHistoryEntryDecodesLegacyPayloadWithoutLanguage() throws {
        // Persisted before languageCode existed — must decode, not be set aside.
        let legacy = Data("""
        {"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","date":700000000,
         "text":"hello there","duration":1.5}
        """.utf8)
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: legacy)
        XCTAssertEqual(decoded.text, "hello there")
        XCTAssertNil(decoded.languageCode)
    }
}

final class SettingsStoreTests: XCTestCase {
    // One fixed suite, emptied on the way in rather than a fresh UUID per run.
    // removePersistentDomain empties the domain but cfprefsd rewrites the plist
    // asynchronously afterwards, so a random name leaves a file in
    // ~/Library/Preferences every time that race is lost. A stable name still
    // isolates and can leave at most one.
    private static let suite = "aloud-tests-settings-store"

    private func freshDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: Self.suite)!
        defaults.removePersistentDomain(forName: Self.suite)
        return defaults
    }

    func testRoundTrip() {
        let suite = Self.suite
        let defaults = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let s1 = SettingsStore(defaults: defaults)
        XCTAssertEqual(s1.hotkey, .default)
        let custom = Hotkey(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue, isModifierKey: false)
        s1.hotkey = custom
        s1.launchAtLogin = true
        s1.microphoneUID = "some-uid"
        s1.historyLimit = 10

        let s2 = SettingsStore(defaults: defaults)
        XCTAssertEqual(s2.hotkey, custom)
        XCTAssertTrue(s2.launchAtLogin)
        XCTAssertEqual(s2.microphoneUID, "some-uid")
        XCTAssertEqual(s2.historyLimit, 10)
    }

    // A key in two slots means one of them silently never fires: the dictation
    // key keeps it, the hands-free key beats the command key, losers clear.
    func testCollidingKeysAreDropped() {
        let suite = Self.suite
        let defaults = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        let other = Hotkey(keyCode: 49, modifiers: 0, isModifierKey: false)

        settings.handsFreeHotkey = settings.hotkey
        settings.commandHotkey = other
        XCTAssertTrue(settings.dropCollidingKeys())
        XCTAssertNil(settings.handsFreeHotkey)
        XCTAssertEqual(settings.commandHotkey, other, "a unique command key survives")

        settings.handsFreeHotkey = other
        XCTAssertTrue(settings.dropCollidingKeys())
        XCTAssertEqual(settings.handsFreeHotkey, other)
        XCTAssertNil(settings.commandHotkey, "command key loses to the hands-free key")

        XCTAssertFalse(settings.dropCollidingKeys(), "no collisions left to drop")
    }
}

final class HotkeyDisplayTests: XCTestCase {
    func testDisplayNames() {
        XCTAssertEqual(Hotkey.default.displayName, "⌃⌥")
        XCTAssertEqual(loneOption.displayName, "Left ⌥")
        let withMods = Hotkey(keyCode: 49, modifiers: CGEventFlags.maskCommand.rawValue, isModifierKey: false)
        XCTAssertEqual(withMods.displayName, "⌘Space")
    }
}
