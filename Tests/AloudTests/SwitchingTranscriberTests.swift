import XCTest
@testable import Aloud

// Routing rules for the primary/fallback composite: the primary always wins
// once ready, the fallback only ever covers after explicit activation, and
// state reporting keeps download progress visible to the UI.
final class SwitchingTranscriberTests: XCTestCase {

    final class FakeTranscriber: Transcriber {
        var state: TranscriberState
        var modelIsDownloaded: Bool
        var prepareError: Error?
        private(set) var transcribeCount = 0
        let name: String

        init(name: String, state: TranscriberState, downloaded: Bool = false) {
            self.name = name
            self.state = state
            self.modelIsDownloaded = downloaded
        }

        func prepare(onProgress: @escaping @Sendable (Double) -> Void) async throws {
            if let prepareError { throw prepareError }
            state = .ready
        }

        func transcribe(samples: [Float]) async throws -> Transcription {
            transcribeCount += 1
            return Transcription(text: name, confidence: 1, audioDuration: 0, processingTime: 0)
        }

        func transcribe(file: URL) async throws -> Transcription {
            try await transcribe(samples: [])
        }
    }

    struct Failure: Error {}

    func testMirrorsPrimaryStateWhenNoFallbackActive() {
        let primary = FakeTranscriber(name: "primary", state: .downloading(progress: 0.5))
        let sut = SwitchingTranscriber(primary: primary, fallback: FakeTranscriber(name: "fb", state: .modelMissing))
        XCTAssertEqual(sut.state, .downloading(progress: 0.5))
        XCTAssertFalse(sut.usingFallback)
    }

    func testActivatedFallbackCoversWhilePrimaryDownloads() async throws {
        let primary = FakeTranscriber(name: "primary", state: .downloading(progress: 0.2))
        let fallback = FakeTranscriber(name: "fb", state: .modelMissing)
        let sut = SwitchingTranscriber(primary: primary, fallback: fallback)

        let ok = await sut.activateFallback()
        XCTAssertTrue(ok)
        XCTAssertEqual(sut.state, .ready)
        XCTAssertTrue(sut.usingFallback)
        let result = try await sut.transcribe(samples: [])
        XCTAssertEqual(result.text, "fb")
    }

    func testPrimaryTakesOverSilentlyOnceReady() async throws {
        let primary = FakeTranscriber(name: "primary", state: .downloading(progress: 0.9))
        let fallback = FakeTranscriber(name: "fb", state: .ready)
        let sut = SwitchingTranscriber(primary: primary, fallback: fallback)
        _ = await sut.activateFallback()

        primary.state = .ready   // download finished in the background
        XCTAssertFalse(sut.usingFallback)
        let result = try await sut.transcribe(samples: [])
        XCTAssertEqual(result.text, "primary")
        XCTAssertEqual(fallback.transcribeCount, 0)
    }

    func testFailedFallbackActivationReportsFalse() async {
        let fallback = FakeTranscriber(name: "fb", state: .modelMissing)
        fallback.prepareError = Failure()
        let sut = SwitchingTranscriber(primary: FakeTranscriber(name: "primary", state: .modelMissing),
                                       fallback: fallback)
        let ok = await sut.activateFallback()
        XCTAssertFalse(ok)
        XCTAssertFalse(sut.usingFallback)
        XCTAssertEqual(sut.state, .modelMissing)
    }

    func testNoFallbackConfigured() async {
        let sut = SwitchingTranscriber(primary: FakeTranscriber(name: "primary", state: .modelMissing),
                                       fallback: nil)
        let ok = await sut.activateFallback()
        XCTAssertFalse(ok)
        XCTAssertEqual(sut.state, .modelMissing)
    }

    // MARK: a language the primary can't hear

    // The one case where a ready primary is the wrong engine: the user
    // declared a language it doesn't cover, so basic dictation stays in charge
    // instead of being handed back the moment the download lands.
    func testDeclaredLanguageKeepsTheFallbackEvenWithAReadyPrimary() async throws {
        let primary = FakeTranscriber(name: "primary", state: .ready)
        let fallback = FakeTranscriber(name: "fb", state: .ready)
        let sut = SwitchingTranscriber(primary: primary, fallback: fallback)
        _ = await sut.activateFallback()

        sut.requiresFallback = true
        XCTAssertTrue(sut.usingFallback)
        XCTAssertEqual(sut.state, .ready)
        let result = try await sut.transcribe(samples: [])
        XCTAssertEqual(result.text, "fb")
        XCTAssertEqual(primary.transcribeCount, 0)
    }

    // Taking the language back out hands the session straight back — no
    // reactivation, no relaunch.
    func testDroppingTheLanguageReturnsToThePrimary() async throws {
        let primary = FakeTranscriber(name: "primary", state: .ready)
        let sut = SwitchingTranscriber(primary: primary,
                                       fallback: FakeTranscriber(name: "fb", state: .ready))
        _ = await sut.activateFallback()
        sut.requiresFallback = true

        sut.requiresFallback = false
        XCTAssertFalse(sut.usingFallback)
        let result = try await sut.transcribe(samples: [])
        XCTAssertEqual(result.text, "primary")
    }

    // Asked for and unavailable — a fallback that won't come up, or no
    // fallback engine on this Mac at all. The language can't be honoured, and
    // reporting "setup needed" over dictation that works would be worse than
    // transcribing it badly: the primary runs and stays ready, and Settings
    // carries the warning about the language.
    func testLanguageWantsAFallbackThatCannotRun() async throws {
        let fallback = FakeTranscriber(name: "fb", state: .modelMissing)
        fallback.prepareError = Failure()
        let sut = SwitchingTranscriber(primary: FakeTranscriber(name: "primary", state: .ready),
                                       fallback: fallback)
        _ = await sut.activateFallback()
        sut.requiresFallback = true
        XCTAssertFalse(sut.usingFallback)
        XCTAssertEqual(sut.state, .ready)
        let result = try await sut.transcribe(samples: [])
        XCTAssertEqual(result.text, "primary")
    }

    func testLanguageWithNoFallbackEngineStillDictates() async throws {
        let sut = SwitchingTranscriber(primary: FakeTranscriber(name: "primary", state: .ready),
                                       fallback: nil)
        sut.requiresFallback = true
        XCTAssertFalse(sut.usingFallback)
        XCTAssertEqual(sut.state, .ready)
        let result = try await sut.transcribe(samples: [])
        XCTAssertEqual(result.text, "primary")
    }
}
