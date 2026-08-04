import AVFoundation
import XCTest
@testable import Aloud

// A voice of the test's own making.
//
// macOS offers no way to build an `AVSpeechSynthesisVoice` with chosen
// properties, so it is subclassed — which is what turns "what does the catalog
// do on a Mac with only one gender installed, or with nothing but a novelty
// voice" from a question nobody could ask into an ordinary fixture.
// `VoiceCatalog.installedSystemVoices` is the seam the catalog already carries
// for exactly this.
private final class SyntheticVoice: AVSpeechSynthesisVoice {
    private let synthesizedIdentifier: String
    private let synthesizedName: String
    private let synthesizedLanguage: String
    private let synthesizedGender: AVSpeechSynthesisVoiceGender
    private let synthesizedQuality: AVSpeechSynthesisVoiceQuality

    init(identifier: String,
         name: String,
         language: String,
         gender: AVSpeechSynthesisVoiceGender,
         quality: AVSpeechSynthesisVoiceQuality) {
        synthesizedIdentifier = identifier
        synthesizedName = name
        synthesizedLanguage = language
        synthesizedGender = gender
        synthesizedQuality = quality
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("fixtures are not archived") }

    override var identifier: String { synthesizedIdentifier }
    override var name: String { synthesizedName }
    override var language: String { synthesizedLanguage }
    override var gender: AVSpeechSynthesisVoiceGender { synthesizedGender }
    override var quality: AVSpeechSynthesisVoiceQuality { synthesizedQuality }
}

// The app's own language, which is what the catalog filters on. The fixtures
// speak it so a test says the same thing on a Mac set to German as on one set
// to English.
private var fixtureLanguage: String {
    String(Locale.current.identifier.prefix(2)).lowercased() + "-US"
}

// One of the modern voice bundles — the only prefix the catalog will consider.
private func systemVoice(_ gender: VoiceGender,
                         named name: String = "Fixture",
                         quality: AVSpeechSynthesisVoiceQuality = .default,
                         identifier: String? = nil) -> AVSpeechSynthesisVoice {
    SyntheticVoice(identifier: identifier ?? "com.apple.voice.fixture.\(fixtureLanguage).\(name)",
                   name: name,
                   language: fixtureLanguage,
                   gender: gender == .female ? .female : .male,
                   quality: quality)
}

// Run `body` on a Mac whose installed voices are exactly these.
private func withVoices(_ voices: [AVSpeechSynthesisVoice], _ body: () -> Void) {
    let installed = VoiceCatalog.installedSystemVoices
    defer {
        VoiceCatalog.installedSystemVoices = installed
        VoiceCatalog.refresh()
    }
    VoiceCatalog.installedSystemVoices = { voices }
    VoiceCatalog.refresh()
    body()
}

// Aloud's own voice for a side, served by an engine this app never fetches —
// so it is reliably not on disk, on a developer's Mac and on a bare runner
// alike. Without one of these the stand-in branch of `SpeakerFactory` is
// unreachable on any machine that has downloaded the real voices, which is
// every machine anybody develops on.
private func undownloadedVoice(for gender: VoiceGender) -> VoiceOption {
    VoiceOption(id: "test.enhanced.\(gender.rawValue)",
                name: "Test \(gender.rawValue)",
                gender: gender,
                region: nil,
                source: .enhanced(.pocket, style: ""))
}

// Which macOS voice a speaker was built around.
//
// Read by reflection because `SpeakerFactory.standIn(for:)` and
// `SystemSpeaker.voiceIdentifier` are both private, and the answer is the whole
// point of the stand-in: a speaker of the wrong gender is indistinguishable
// from one of the right gender until somebody hears it.
private func chosenVoice(of speaker: Speaker,
                         file: StaticString = #filePath,
                         line: UInt = #line) -> String? {
    for child in Mirror(reflecting: speaker).children where child.label == "voiceIdentifier" {
        return child.value as? String
    }
    XCTFail("SystemSpeaker no longer stores its voice under `voiceIdentifier`", file: file, line: line)
    return nil
}

// The voice choice is one question — female or male — and Aloud answers the
// rest: which installed voice serves that side, and what to do when the Mac
// has none. Both halves fail quietly if they fail at all (an agent that speaks
// in the wrong voice, or in no voice), so they are pinned here.
//
// The Mac's own voices are supplied by the fixtures above rather than read off
// the machine. Several of these tests used to be written against whatever was
// installed, which made them unfailable: `SpeakerFactory.make(x).modelIsDownloaded`
// is `true` for every `x` there is — `SystemSpeaker` hardcodes it, and the
// factory only ever returns a `NeuralSpeaker` from inside an
// `if enhanced.modelIsDownloaded` branch — so half a dozen assertions were
// re-stating the type system.
final class VoiceCatalogTests: XCTestCase {

    override func setUp() {
        super.setUp()
        VoiceCatalog.refresh()
    }

    // The whole promise of the picker: pick a side, get a voice on that side.
    //
    // On a Mac that has a voice for both, neither may borrow the other's — the
    // fallback across the gender line exists for a machine that is missing one,
    // and reaching for it here would mean the choice quietly did nothing.
    func testEachOfferedGenderResolvesToAVoiceOfThatSide() {
        withVoices([systemVoice(.female, named: "Fem"), systemVoice(.male, named: "Masc")]) {
            for gender in VoiceCatalog.availableGenders {
                let voice = VoiceCatalog.resolved(gender: gender)
                XCTAssertFalse(voice.name.isEmpty, "\(gender.rawValue) resolves to a nameless voice")
                XCTAssertEqual(voice.gender, gender,
                               "\(gender.rawValue) was asked for and something else answered")
            }
        }
    }

    // Aloud's own voices are two different engines because neither covers both
    // sides — a regression here is one gender silently losing its good voice.
    func testBothSidesHaveOneOfAloudsOwnVoices() {
        for gender in VoiceGender.allCases {
            let mine = VoiceCatalog.enhanced[gender]
            XCTAssertNotNil(mine, "\(gender.rawValue) has no voice of Aloud's own")
            XCTAssertEqual(mine?.gender, gender)
            XCTAssertTrue(mine?.isEnhanced == true)
        }
    }

    // What the Mac itself offers is read per side. A machine with only one
    // gender installed must report nothing for the other rather than handing
    // back the voice it does have — that answer travels into `standIn`, where
    // it decides which voice a question is asked in.
    func testTheMacsOwnVoicesAreReadPerSide() {
        withVoices([systemVoice(.male, named: "Masc")]) {
            XCTAssertEqual(VoiceCatalog.systemVoice(for: .male)?.gender, .male)
            XCTAssertEqual(VoiceCatalog.systemVoice(for: .male)?.name, "Masc")
            XCTAssertNil(VoiceCatalog.systemVoice(for: .female),
                         "a side with nothing installed must report nothing, "
                         + "not quietly answer with the other side's voice")
        }
    }

    // macOS ships a compact voice for every locale and downloads better ones on
    // demand. Picking the compact one when a premium is sitting there is the
    // upgrade going unused, silently, forever.
    func testTheBestVoiceOnASideIsTheOneOffered() {
        withVoices([systemVoice(.female, named: "Compact", quality: .default),
                    systemVoice(.female, named: "Premium", quality: .premium),
                    systemVoice(.female, named: "Enhanced", quality: .enhanced)]) {
            XCTAssertEqual(VoiceCatalog.systemVoice(for: .female)?.name, "Premium")
        }
        // And order of enumeration decides nothing: the same three the other
        // way round pick the same voice.
        withVoices([systemVoice(.female, named: "Premium", quality: .premium),
                    systemVoice(.female, named: "Compact", quality: .default)]) {
            XCTAssertEqual(VoiceCatalog.systemVoice(for: .female)?.name, "Premium")
        }
    }

    // Novelty voices ("Bubbles", "Trinoids") and the robotic Eloquence family
    // live outside the `com.apple.voice.` bundles, and none of them belongs in
    // the mouth of an agent asking you a question. Nor does a voice that will
    // not say which side it is on, since that is the only thing being chosen.
    func testNoveltyVoicesAndGenderlessVoicesAreNeverOffered() {
        withVoices([systemVoice(.female, named: "Bubbles",
                                identifier: "com.apple.speech.synthesis.voice.Bubbles"),
                    SyntheticVoice(identifier: "com.apple.voice.fixture.\(fixtureLanguage).Nobody",
                                   name: "Nobody",
                                   language: fixtureLanguage,
                                   gender: .unspecified,
                                   quality: .premium)]) {
            XCTAssertNil(VoiceCatalog.systemVoice(for: .female),
                         "a novelty voice is not a voice to be asked a question in")
            XCTAssertNil(VoiceCatalog.systemVoice(for: .male),
                         "a voice that will not declare a side cannot be chosen by side")
        }
    }

    // A voice for a language this Mac is not set to is not a voice for this
    // Mac: answering an English user in Portuguese is worse than the compact
    // English voice it displaced.
    func testAVoiceForAnotherLanguageIsNotOffered() {
        withVoices([SyntheticVoice(identifier: "com.apple.voice.fixture.zz-ZZ.Elsewhere",
                                   name: "Elsewhere",
                                   language: "zz-ZZ",
                                   gender: .female,
                                   quality: .premium)]) {
            XCTAssertNil(VoiceCatalog.systemVoice(for: .female, language: "en_US"))
        }
    }

    // The female voice's engine speaks English and nothing else; the male
    // one's speaks 31 languages. Claiming a voice for a language it cannot
    // read would mean a German user waiting for a download that would never
    // help them, and then being read German with English vowels.
    func testAloudsVoicesAreOnlyClaimedForLanguagesTheySpeak() {
        XCTAssertNotNil(VoiceCatalog.enhancedVoice(for: .female, language: "en_US"))
        XCTAssertNil(VoiceCatalog.enhancedVoice(for: .female, language: "pt_BR"))
        XCTAssertNotNil(VoiceCatalog.enhancedVoice(for: .male, language: "en_US"))
        XCTAssertNotNil(VoiceCatalog.enhancedVoice(for: .male, language: "de_DE"))
    }

    // A stored speed is a number on disk; anything can be in it.
    func testSpeedIsAlwaysUsable() {
        XCTAssertEqual(VoiceSpeed.clamped(0), VoiceSpeed.slowest)
        XCTAssertEqual(VoiceSpeed.clamped(99), VoiceSpeed.fastest)
        XCTAssertEqual(VoiceSpeed.clamped(VoiceSpeed.normal), VoiceSpeed.normal)
        XCTAssertEqual(VoiceSpeed.clamped(.nan), VoiceSpeed.slowest,
                       "a NaN speed has to land somewhere sayable")
    }

    func testSpeedReadsAsAMultiple() {
        XCTAssertEqual(VoiceSpeed.label(1), "1×")
        XCTAssertEqual(VoiceSpeed.label(1.25), "1.25×")
        XCTAssertEqual(VoiceSpeed.label(1.2), "1.2×")
        XCTAssertEqual(VoiceSpeed.label(0.7), "0.7×")
    }

    // The stand-in, and the one thing about it a user would notice: a voice of
    // Aloud's own that is not on disk yet is covered by the Mac's best voice ON
    // THAT SIDE. Falling back to "whatever this Mac speaks best" would answer a
    // question about a male voice in a female one, which reads as the setting
    // having been ignored — and the side is the entire setting.
    //
    // `standIn` had no test of any kind. What stood here instead was
    // `XCTAssertTrue(SpeakerFactory.make(x).modelIsDownloaded)`, which is true
    // for every `x` by construction and could not have failed.
    func testAVoiceThatIsNotOnDiskStandsInOnTheSameSide() {
        withVoices([systemVoice(.female, named: "Fem"), systemVoice(.male, named: "Masc")]) {
            for gender in VoiceGender.allCases {
                let speaker = SpeakerFactory.make(undownloadedVoice(for: gender))
                XCTAssertTrue(speaker is SystemSpeaker,
                              "a voice whose assets are absent has to degrade to one that "
                              + "speaks today, not to a speaker that will throw")
                guard case .system(let expected)? =
                        VoiceCatalog.systemVoice(for: gender)?.source else {
                    return XCTFail("the fixture must offer a system voice for \(gender.rawValue)")
                }
                XCTAssertEqual(chosenVoice(of: speaker), expected,
                               "a question about a \(gender.rawValue) voice was handed "
                               + "a voice from the other side")
            }
        }
    }

    // The two sides really are different voices in that fixture, so the test
    // above is comparing something. Without this it would still pass if
    // `standIn` handed back one voice for both.
    func testTheTwoSidesOfTheFixtureAreDifferentVoices() {
        withVoices([systemVoice(.female, named: "Fem"), systemVoice(.male, named: "Masc")]) {
            XCTAssertNotEqual(VoiceCatalog.systemVoice(for: .female)?.id,
                              VoiceCatalog.systemVoice(for: .male)?.id)
        }
    }

    // A side the Mac cannot cover at all falls back to the system synthesizer's
    // own default — nil, which is what `SystemSpeaker` reads as "whatever this
    // Mac speaks best". Silence would be the alternative.
    func testASideTheMacCannotCoverFallsBackToTheDefaultVoice() {
        withVoices([]) {
            let speaker = SpeakerFactory.make(undownloadedVoice(for: .male))
            XCTAssertTrue(speaker is SystemSpeaker)
            XCTAssertNil(chosenVoice(of: speaker),
                         "with nothing to stand in, the synthesizer's own default is the answer")
        }
    }

    // And Aloud's own voice is used exactly when it is on disk — never before,
    // or `speak` throws where it should have degraded; never skipped after, or
    // the download nobody was asked about bought nothing.
    func testAloudsOwnVoiceIsUsedExactlyWhenItIsOnDisk() {
        for gender in VoiceGender.allCases {
            guard let mine = VoiceCatalog.enhanced[gender] else {
                return XCTFail("\(gender.rawValue) has no voice of Aloud's own")
            }
            let speaker = SpeakerFactory.make(mine)
            if EnhancedVoices.isReady(mine) {
                XCTAssertTrue(speaker is NeuralSpeaker,
                              "\(gender.rawValue)'s downloaded voice is sitting on disk unused")
            } else {
                XCTAssertTrue(speaker is SystemSpeaker,
                              "\(gender.rawValue)'s voice is not here yet and must be stood in for")
            }
        }
    }

    func testFactoryCarriesTheSpeedThrough() {
        let speaker = SpeakerFactory.make(nil, speed: 1.25)
        XCTAssertEqual(speaker.speed, 1.25)
        // And refuses one that isn't sayable.
        XCTAssertEqual(SpeakerFactory.make(nil, speed: 9).speed, VoiceSpeed.fastest)
    }
}

// One speaker per voice, shared by everything that speaks — the agent bridge
// and the preview button in Settings both go through here.
//
// The pool had no test at all, and its two silent failure modes are worth a
// file of their own: a `speed: nil` call that resets a pace the user chose (the
// launch-time warm-up is exactly such a caller, so every agent question would
// come out at 1.0× regardless of the Settings slider, with nothing anywhere
// saying so), and a cache keyed loosely enough that two voices share one
// speaker or one voice gets two.
//
// Headless throughout: nothing here plays, downloads, or synthesizes.
@MainActor
final class SpeakerPoolTests: XCTestCase {

    // A voice of our own making, so these tests neither depend on nor disturb
    // whatever the Mac has installed — the pool is process-global.
    private func fakeSystemVoice(_ suffix: String = UUID().uuidString) -> VoiceOption {
        VoiceOption(id: "test.system.\(suffix)",
                    name: "Test \(suffix.prefix(4))",
                    gender: .female,
                    region: nil,
                    source: .system(""))
    }

    // The invariant `speaker(for:speed:)` documents in its own comment, and the
    // one that costs the user their Settings slider if it goes: callers that
    // only want the instance — warming it, stopping it — pass no speed, and
    // must not reset the pace somebody chose.
    func testANilSpeedLeavesThePaceTheUserChose() {
        let voice = fakeSystemVoice()
        let speaker = SpeakerPool.speaker(for: voice, speed: 1.3)
        XCTAssertEqual(speaker.speed, 1.3)

        let again = SpeakerPool.speaker(for: voice)
        XCTAssertTrue(speaker === again, "the same voice must not be built twice")
        XCTAssertEqual(again.speed, 1.3,
                       "a caller that only wanted the instance reset the user's pace")
    }

    // …and a speed that IS given still applies, so the slider works.
    func testASpeedThatIsGivenIsApplied() {
        let voice = fakeSystemVoice()
        let speaker = SpeakerPool.speaker(for: voice, speed: 1.0)
        _ = SpeakerPool.speaker(for: voice, speed: 0.8)
        XCTAssertEqual(speaker.speed, 0.8)
        // And an unsayable one is clamped rather than passed to the engine.
        _ = SpeakerPool.speaker(for: voice, speed: 99)
        XCTAssertEqual(speaker.speed, VoiceSpeed.fastest)
    }

    // Keyed on the voice's id, which is the whole point: a side whose voice
    // changes underneath it — Aloud's own arriving and replacing the Mac's
    // stand-in — has to get a new speaker rather than the old one under a new
    // name, and two different voices must never share one.
    func testOneSpeakerPerVoiceAndNeverOneForTwo() {
        let one = fakeSystemVoice()
        let other = fakeSystemVoice()
        XCTAssertNotEqual(one.id, other.id)

        XCTAssertTrue(SpeakerPool.speaker(for: one) === SpeakerPool.speaker(for: one),
                      "the same id has to come back as the same instance")
        XCTAssertFalse(SpeakerPool.speaker(for: one) === SpeakerPool.speaker(for: other),
                       "two voices sharing one speaker is one of them speaking in the other's voice")
    }

    // The download path builds a speaker to fetch the assets with. Without
    // `adopt` it was thrown away and the very next call loaded the same CoreML
    // chain all over again.
    func testAnAlreadyLoadedSpeakerIsAdoptedRatherThanRebuilt() {
        let voice = fakeSystemVoice()
        let mine = SpeakerFactory.make(voice, speed: 1.1)
        SpeakerPool.adopt(mine, for: voice)
        XCTAssertTrue(SpeakerPool.speaker(for: voice) === mine)
        XCTAssertEqual(SpeakerPool.speaker(for: voice).speed, 1.1,
                       "adopting must not re-pace what was handed over")
    }

    // Adopting over a voice the pool already serves would swap the instance
    // under whoever is mid-sentence through it.
    func testAdoptingDoesNotDisplaceASpeakerAlreadyInUse() {
        let voice = fakeSystemVoice()
        let first = SpeakerPool.speaker(for: voice)
        SpeakerPool.adopt(SpeakerFactory.make(voice), for: voice)
        XCTAssertTrue(SpeakerPool.speaker(for: voice) === first)
    }

    // Only one of Aloud's own voices stays resident, and the system voices are
    // deliberately left alone: they hold no models, and dropping the one
    // standing in for a side mid-download would discard a speaker something
    // else may still be speaking through.
    func testKeepingOneVoiceLeavesTheSystemStandInsAlone() {
        let keep = fakeSystemVoice()
        let bystander = fakeSystemVoice()
        let kept = SpeakerPool.speaker(for: keep)
        let untouched = SpeakerPool.speaker(for: bystander)

        SpeakerPool.keepOnlyEnhanced(keep)

        XCTAssertTrue(SpeakerPool.speaker(for: keep) === kept)
        XCTAssertTrue(SpeakerPool.speaker(for: bystander) === untouched,
                      "a system voice holds no model, so there is nothing to evict it for")
    }

    // A system voice needs nothing downloading, so it is ready the instant it
    // is asked for — which is what makes the degraded tier work at all.
    func testASystemVoiceIsAlwaysReady() {
        XCTAssertTrue(EnhancedVoices.isReady(fakeSystemVoice()))
        for gender in VoiceGender.allCases {
            if let theirs = VoiceCatalog.systemVoice(for: gender) {
                XCTAssertTrue(EnhancedVoices.isReady(theirs), "\(gender.rawValue)")
            }
        }
    }

    // The nil-speed caller that runs at launch. Warming a side must not be the
    // thing that quietly puts every later utterance back to 1.0×.
    //
    // The speaker is one of the test's own, put in the pool before `warm` can
    // ask for it. That is not a convenience: this used to skip itself whenever
    // the side resolved to one of Aloud's own downloaded voices — which is true
    // on every machine anybody develops on, so the assertions protecting the
    // Settings speed slider ran only where nobody was watching. And where they
    // did run, `warm` left a real `AVSpeechSynthesizer.write` going in an
    // un-awaited Task that outlived the test. A stand-in removes both, and
    // leaves the question — does warming reset a pace somebody chose — exactly
    // as it was.
    func testWarmingASideDoesNotResetItsPace() {
        let gender = VoiceCatalog.defaultGender
        let voice = VoiceCatalog.resolved(gender: gender)
        SpeakerPool.adopt(StubSpeaker(), for: voice)

        let speaker = SpeakerPool.speaker(for: voice, speed: 1.15)
        XCTAssertTrue(speaker is StubSpeaker,
                      "something else in this process already claimed \(voice.id); "
                      + "this test has to own the speaker it warms")

        EnhancedVoices.shared.warm(gender)

        XCTAssertEqual(SpeakerPool.speaker(for: voice).speed, 1.15,
                       "the launch-time warm-up overwrote the pace from Settings")
        XCTAssertTrue(SpeakerPool.speaker(for: voice) === speaker,
                      "and it must warm the speaker that will actually speak")
    }

    // A Mac with only one gender installed still has to be able to ask a
    // question. `resolved` promises it falls back across the gender line rather
    // than to silence.
    //
    // The Mac's voices are supplied here rather than filtered out of whatever
    // this machine happens to have, so the fixture is the same everywhere —
    // including on a runner with no speech voices at all, where filtering used
    // to leave nothing to fall back TO and the test skipped itself.
    func testASideWithNoVoiceOfItsOwnFallsBackAcrossTheGenderLine() {
        withVoices([systemVoice(.male, named: "Masc")]) {
            XCTAssertNil(VoiceCatalog.systemVoice(for: .female),
                         "the fixture is wrong if the female side still has a system voice")

            let resolved = VoiceCatalog.resolved(gender: .female)
            // Both halves assert. Aloud's own female voice, when its assets are
            // on disk, is preferred over any fallback and is the right answer;
            // when they are not, the male side has to be borrowed rather than
            // the question going unasked. Which of the two applies is a fact
            // about the machine, and there is no seam to decide it — but
            // neither branch is allowed to be a no-op, which is what the skip
            // that stood here made of it.
            if VoiceCatalog.enhancedVoice(for: .female).map(EnhancedVoices.isReady) == true {
                XCTAssertEqual(resolved.gender, .female,
                               "Aloud's own downloaded voice must win over any stand-in")
                XCTAssertTrue(resolved.isEnhanced)
            } else {
                XCTAssertEqual(resolved.gender, .male,
                               "a side with no voice must borrow the other's, not go silent")
            }
            XCTAssertFalse(resolved.name.isEmpty)
        }
    }
}

// A speaker that does nothing at all: no synthesizer, no models, no audio.
//
// The pool and the warm-up are pure bookkeeping — which instance serves a
// voice, and whose pace survives — and every one of those questions can be
// asked without anything ever being said out loud.
private final class StubSpeaker: Speaker {
    var state: SpeakerState = .ready
    var speed: Double = VoiceSpeed.normal
    var modelIsDownloaded: Bool { true }
    private(set) var prepared = 0
    private(set) var synthesized: [String] = []

    func prepare() async throws { prepared += 1 }

    func synthesize(_ text: String) async throws -> Speech {
        synthesized.append(text)
        return Speech(samples: [], sampleRate: 16_000, synthesisTime: 0)
    }

    func speak(_ text: String) async throws {}
    func stop() {}
}
