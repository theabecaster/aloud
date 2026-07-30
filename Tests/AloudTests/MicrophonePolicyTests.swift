import XCTest
@testable import Aloud

// The judgement calls behind where the system default input should sit and
// whether the noise filter may run — pure values in, verdict out, no
// Core Audio anywhere.
final class MicrophonePolicyTests: XCTestCase {
    private let boseMic = MicrophonePolicy.Device(uid: "AA-BB-CC:input", name: "Bose QC35 II", isBluetooth: true)
    private let boseOut = MicrophonePolicy.Device(uid: "AA-BB-CC:output", name: "Bose QC35 II", isBluetooth: true)
    private let speakers = MicrophonePolicy.Device(uid: "BuiltInSpeakers", name: "MacBook Pro Speakers", isBluetooth: false)

    func testHeadsetDoublingAsOutputSteersToBuiltIn() {
        XCTAssertEqual(MicrophonePolicy.preferredUID(systemDefaultInput: boseMic,
                                                     defaultOutput: boseOut,
                                                     builtInUID: "BuiltIn"), "BuiltIn")
    }

    func testMatchesByNameWhenUIDsShareNothing() {
        // Some stacks give the halves unrelated UIDs; the product name is
        // then the only thread tying them together.
        let mic = MicrophonePolicy.Device(uid: "bt-hfp-1", name: "AirPods Pro", isBluetooth: true)
        let out = MicrophonePolicy.Device(uid: "bt-a2dp-7", name: "AirPods Pro", isBluetooth: true)
        XCTAssertEqual(MicrophonePolicy.preferredUID(systemDefaultInput: mic,
                                                     defaultOutput: out,
                                                     builtInUID: "BuiltIn"), "BuiltIn")
    }

    func testBluetoothMicWithNonBluetoothOutputIsLeftAlone() {
        XCTAssertNil(MicrophonePolicy.preferredUID(systemDefaultInput: boseMic,
                                                   defaultOutput: speakers,
                                                   builtInUID: "BuiltIn"))
    }

    func testTwoDifferentHeadsetsAreLeftAlone() {
        // Listening on one headset, dictating through another: their music
        // isn't at stake, so the default input stands.
        let out = MicrophonePolicy.Device(uid: "DD-EE-FF:output", name: "AirPods Pro", isBluetooth: true)
        XCTAssertNil(MicrophonePolicy.preferredUID(systemDefaultInput: boseMic,
                                                   defaultOutput: out,
                                                   builtInUID: "BuiltIn"))
    }

    func testNoBuiltInMeansNothingToSteerTo() {
        XCTAssertNil(MicrophonePolicy.preferredUID(systemDefaultInput: boseMic,
                                                   defaultOutput: boseOut,
                                                   builtInUID: nil))
    }

    func testMissingDevicesMeanNoOpinion() {
        XCTAssertNil(MicrophonePolicy.preferredUID(systemDefaultInput: nil,
                                                   defaultOutput: nil,
                                                   builtInUID: "BuiltIn"))
    }

    // Voice processing owns whatever device the Mac is playing through, so
    // it may only engage where that's its job: the built-in speakers, whose
    // sound genuinely bleeds into the microphone. Everything else — a
    // Bluetooth headset whose audio it mangles, external DACs it can wedge
    // into a mismatched aggregate — is off limits.
    func testVoiceProcessingOnlyOnBuiltInOutput() {
        XCTAssertTrue(MicrophonePolicy.voiceProcessingAllowed(outputTransport: .builtIn))
        XCTAssertFalse(MicrophonePolicy.voiceProcessingAllowed(outputTransport: .bluetooth))
        XCTAssertFalse(MicrophonePolicy.voiceProcessingAllowed(outputTransport: .other))
    }

    func testNoOutputAtAllPermitsVoiceProcessing() {
        // Nothing is playing anywhere, so there is nothing to damage.
        XCTAssertTrue(MicrophonePolicy.voiceProcessingAllowed(outputTransport: nil))
    }

    func testBaseUIDStripsOnlyDirectionSuffixes() {
        XCTAssertEqual(MicrophonePolicy.baseUID("AA-BB:input"), "AA-BB")
        XCTAssertEqual(MicrophonePolicy.baseUID("AA-BB:output"), "AA-BB")
        XCTAssertEqual(MicrophonePolicy.baseUID("AA-BB:inputx"), "AA-BB:inputx")
        XCTAssertEqual(MicrophonePolicy.baseUID("plain"), "plain")
    }
}
