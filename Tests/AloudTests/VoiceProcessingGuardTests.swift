import XCTest
@testable import Aloud

// The two judgement calls behind "Aloud stopped hearing me when I turned on
// noise reduction". Both directions of error matter, so both are pinned here.
final class VoiceProcessingGuardTests: XCTestCase {

    // MARK: rescuing a dead session

    func testRescuesASessionThatHasHeardNothing() {
        XCTAssertTrue(VoiceProcessingGuard.shouldFallBack(
            voiceProcessingActive: true, heardAnything: false, alreadyFellBack: false))
    }

    func testLeavesAWorkingSessionAlone() {
        XCTAssertFalse(VoiceProcessingGuard.shouldFallBack(
            voiceProcessingActive: true, heardAnything: true, alreadyFellBack: false))
    }

    // Raw capture has nothing to fall back to.
    func testDoesNothingWhenVoiceProcessingIsntEvenOn() {
        XCTAssertFalse(VoiceProcessingGuard.shouldFallBack(
            voiceProcessingActive: false, heardAnything: false, alreadyFellBack: false))
    }

    // Once per session: rebuilding capture in a loop would be worse than the
    // silence it's trying to fix.
    func testNeverFallsBackTwice() {
        XCTAssertFalse(VoiceProcessingGuard.shouldFallBack(
            voiceProcessingActive: true, heardAnything: false, alreadyFellBack: true))
    }

    // MARK: blaming the device

    // The only case that convicts: voice processing heard nothing, raw capture
    // then heard something. That difference is the feature.
    func testDistrustsADeviceOnlyOnAProvenDifference() {
        XCTAssertTrue(VoiceProcessingGuard.shouldDistrustDevice(
            fellBack: true, heardAfterFallback: true))
    }

    // A dictation started in a silent room hears nothing either way. Disabling
    // the feature on that evidence would punish a perfectly good microphone.
    func testAQuietRoomIsNotEvidence() {
        XCTAssertFalse(VoiceProcessingGuard.shouldDistrustDevice(
            fellBack: true, heardAfterFallback: false))
    }

    func testASessionThatNeverFellBackConvictsNobody() {
        XCTAssertFalse(VoiceProcessingGuard.shouldDistrustDevice(
            fellBack: false, heardAfterFallback: true))
        XCTAssertFalse(VoiceProcessingGuard.shouldDistrustDevice(
            fellBack: false, heardAfterFallback: false))
    }
}
