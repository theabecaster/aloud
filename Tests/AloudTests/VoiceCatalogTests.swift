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

    // The whole promise of the picker: pick a side, get a voice from it.
    func testEachOfferedGenderHasAVoice() {
        for gender in VoiceCatalog.availableGenders {
            XCTAssertTrue(VoiceCatalog.enhancedVoice(for: gender) != nil
                          || VoiceCatalog.systemVoice(for: gender) != nil,
                          "\(gender.rawValue) is offered but nothing can speak it")
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

    func testOfferedGendersAreNeverEmpty() {
        XCTAssertFalse(VoiceCatalog.availableGenders.isEmpty,
                       "a picker with no options is worse than one whose choice barely matters")
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
