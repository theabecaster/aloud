import XCTest
@testable import Aloud

// The two tiers the Languages picker splits on, and the promise that every
// language it offers is one some engine can hear.
final class DictationLanguageTierTests: XCTestCase {
    func testFullQualityIsThePrimaryEnginesOwnList() {
        XCTAssertTrue(DictationLanguages.isFullQuality("en"))
        XCTAssertTrue(DictationLanguages.isFullQuality("el"))
        XCTAssertFalse(DictationLanguages.isFullQuality("ja"))
    }

    func testTheTwoTiersNeverOverlap() {
        let full = Set(DictationLanguages.supported)
        XCTAssertTrue(DictationLanguages.basicOnly.allSatisfy { !full.contains($0) })
        // Codes are ISO 639-1 language codes, not regioned locales — the
        // picker keys its rows on them and would show duplicates otherwise.
        XCTAssertEqual(Set(DictationLanguages.basicOnly).count,
                       DictationLanguages.basicOnly.count)
        XCTAssertTrue(DictationLanguages.basicOnly.allSatisfy { !$0.contains("-") })
    }

    func testEnglishIsAlwaysDictatable() {
        // The floor SettingsStore falls back to when the system language is
        // one no engine here can hear.
        XCTAssertTrue(DictationLanguages.isDictatable("en"))
        XCTAssertFalse(DictationLanguages.isDictatable("zz"))
    }
}
