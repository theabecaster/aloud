import AVFoundation
import XCTest
@testable import Aloud

// The voice choice is one question — female or male — and Aloud answers the
// rest: which installed voice serves that side, and what to do when the Mac
// has none. Both halves fail quietly if they fail at all (an agent that speaks
// in the wrong voice, or in no voice), so they are pinned here.
//
// Everything is written to tolerate a bare machine: a CI runner can have no
// speech voices at all, and a catalog that is empty there is correct.
final class VoiceCatalogTests: XCTestCase {

    override func setUp() {
        super.setUp()
        VoiceCatalog.refresh()
    }

    // The whole promise of the picker: pick a side, get a voice that can speak.
    //
    // Asserted through `resolved` and the factory rather than by re-stating the
    // predicate `availableGenders` is built from — which is what this used to
    // do, so it could only ever agree with itself, and it agreed by *failing*
    // on exactly the Mac the header promises to tolerate: one with no voices
    // for the app's language, where the list falls back to both genders and
    // neither has a voice behind it. Going through `resolved` asks the question
    // that matters, and has an answer everywhere.
    func testEachOfferedGenderResolvesToAVoiceThatCanSpeak() {
        for gender in VoiceCatalog.availableGenders {
            let voice = VoiceCatalog.resolved(gender: gender)
            XCTAssertFalse(voice.name.isEmpty, "\(gender.rawValue) resolves to a nameless voice")
            XCTAssertTrue(SpeakerFactory.make(voice).modelIsDownloaded,
                          "\(gender.rawValue) is offered but what it resolves to cannot speak today")
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

    // A picker with no options is worse than one whose choice barely matters,
    // so the list is never empty — and, because it is not empty by
    // construction, what is worth pinning is that every entry in it is a
    // gender the app knows how to store and draw.
    func testOfferedGendersAreNeverEmptyAndAreAlwaysRealGenders() {
        let offered = VoiceCatalog.availableGenders
        XCTAssertFalse(offered.isEmpty,
                       "a picker with no options is worse than one whose choice barely matters")
        XCTAssertEqual(Set(offered).count, offered.count, "no gender may be offered twice")
        for gender in offered {
            XCTAssertTrue(VoiceGender.allCases.contains(gender))
            XCTAssertFalse(gender.label.isEmpty, "every row in the picker needs a caption")
        }
    }

    // Whatever is stored, there is always a voice to speak with — including on
    // a Mac that has none of the chosen gender installed.
    func testAlwaysResolvesToSomething() {
        for gender in VoiceGender.allCases {
            XCTAssertFalse(VoiceCatalog.resolved(gender: gender).name.isEmpty)
        }
        XCTAssertFalse(VoiceCatalog.resolved(gender: nil).name.isEmpty)
    }

    func testResolvingHonoursTheChosenGenderWhenItCan() {
        for gender in VoiceCatalog.availableGenders {
            // Either Aloud's own voice for that side is downloaded, or the Mac
            // has one — otherwise crossing the line is the correct answer.
            guard VoiceCatalog.systemVoice(for: gender) != nil
                    || !VoiceCatalog.isStandingIn(gender) else { continue }
            XCTAssertEqual(VoiceCatalog.resolved(gender: gender).gender, gender)
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

    // The factory's contract: what it hands back can speak right now. The
    // enhanced voice degrades to a system one rather than failing when its
    // assets aren't here.
    func testFactoryOnlyHandsBackAVoiceThatCanSpeak() {
        XCTAssertTrue(SpeakerFactory.make().modelIsDownloaded)
        for gender in VoiceGender.allCases {
            XCTAssertTrue(SpeakerFactory.make(VoiceCatalog.resolved(gender: gender))
                .modelIsDownloaded)
            // Including the voice that hasn't been downloaded yet: asking for
            // it must produce the stand-in, not a speaker that will throw.
            if let mine = VoiceCatalog.enhanced[gender] {
                XCTAssertTrue(SpeakerFactory.make(mine).modelIsDownloaded)
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
    // Only run where warming costs nothing: if this side resolves to one of
    // Aloud's own downloaded voices, `warm` would load a CoreML chain in the
    // background, which is not something a unit test should start.
    func testWarmingASideDoesNotResetItsPace() throws {
        let gender = VoiceCatalog.defaultGender
        let voice = VoiceCatalog.resolved(gender: gender)
        try XCTSkipIf(voice.isEnhanced, "warming a downloaded voice would load its models")

        let speaker = SpeakerPool.speaker(for: voice, speed: 1.15)
        EnhancedVoices.shared.warm(gender)
        XCTAssertEqual(SpeakerPool.speaker(for: voice).speed, 1.15,
                       "the launch-time warm-up overwrote the pace from Settings")
        XCTAssertTrue(SpeakerPool.speaker(for: voice) === speaker,
                      "and it must warm the speaker that will actually speak")
    }

    // A Mac with only one gender installed still has to be able to ask a
    // question. `resolved` promises it falls back across the gender line rather
    // than to silence, and until the voice list could be injected that promise
    // was untestable on any machine that had both — which is every developer
    // machine, and the CI runner too. So it was only ever true by inspection.
    func testAsideWithNoVoiceOfItsOwnFallsBackAcrossTheGenderLine() throws {
        let installed = VoiceCatalog.installedSystemVoices
        defer {
            VoiceCatalog.installedSystemVoices = installed
            VoiceCatalog.refresh()
        }

        // Only the voices macOS reports as male survive, so the female side has
        // nothing of the system's to offer.
        VoiceCatalog.installedSystemVoices = {
            installed().filter { $0.gender == .male }
        }
        VoiceCatalog.refresh()
        try XCTSkipIf(VoiceCatalog.systemVoice(for: .male, language: "en_US") == nil,
                      "this Mac reports no male system voice to fall back to")
        // Aloud's own female voice would be preferred over any fallback, so
        // this only means anything where it is not sitting on disk.
        try XCTSkipIf(VoiceCatalog.enhancedVoice(for: .female)
                        .map(EnhancedVoices.isReady) == true,
                      "Aloud's own female voice is downloaded, so nothing falls back")

        XCTAssertNil(VoiceCatalog.systemVoice(for: .female, language: "en_US"),
                     "the fixture is wrong if the female side still has a system voice")
        XCTAssertEqual(VoiceCatalog.resolved(gender: .female).gender, .male,
                       "a side with no voice must borrow the other's, not go silent")
    }
}
