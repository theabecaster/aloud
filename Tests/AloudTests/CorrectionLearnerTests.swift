import XCTest
@testable import Aloud

final class CorrectionLearnerTests: XCTestCase {
    private var dir: URL!
    private var fileURL: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var settings: SettingsStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("corrections.json")
        suite = "aloud-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        settings = SettingsStore(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    private func candidate(_ from: String, _ to: String) -> CorrectionDiff.Candidate {
        CorrectionDiff.Candidate(from: from, to: to)
    }

    func testThresholdPromotion() {
        let learner = CorrectionLearner(fileURL: fileURL)

        let first = learner.observe([candidate("jon", "Jon")], settings: settings)
        XCTAssertTrue(first.isEmpty, "one sighting is not a pattern")
        XCTAssertEqual(learner.suggestions.first?.status, .pending)
        XCTAssertTrue(learner.readySuggestions.isEmpty)

        let second = learner.observe([candidate("jon", "Jon")], settings: settings)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.from, "jon")
        XCTAssertEqual(second.first?.to, "Jon")
        XCTAssertEqual(learner.readySuggestions.count, 1)
        XCTAssertEqual(learner.readySuggestions.first?.count, 2)

        // Already ready — a third sighting must not report it as newly ready.
        let third = learner.observe([candidate("jon", "Jon")], settings: settings)
        XCTAssertTrue(third.isEmpty)
        XCTAssertEqual(learner.readySuggestions.first?.count, 3)
    }

    func testMatchIsCaseInsensitiveAndToClampsToLatest() {
        let learner = CorrectionLearner(fileURL: fileURL)
        learner.observe([candidate("shelly", "Chellie")], settings: settings)
        let ready = learner.observe([candidate("Shelly", "chellie")], settings: settings)
        XCTAssertEqual(ready.count, 1, "case-different from counts toward the same pair")
        XCTAssertEqual(ready.first?.to, "chellie", "latest observed spelling wins")
    }

    func testDismissIsSticky() {
        let learner = CorrectionLearner(fileURL: fileURL)
        learner.observe([candidate("teh", "the")], settings: settings)
        let ready = learner.observe([candidate("teh", "the")], settings: settings)
        learner.dismiss(ready[0])
        XCTAssertTrue(learner.readySuggestions.isEmpty)

        for _ in 0..<5 {
            let again = learner.observe([candidate("teh", "the")], settings: settings)
            XCTAssertTrue(again.isEmpty, "a dismissed pair never comes back")
        }
        XCTAssertTrue(learner.readySuggestions.isEmpty)
        XCTAssertEqual(learner.suggestions.first?.count, 2, "counting stopped at dismissal")
    }

    func testDismissSurvivesReload() {
        let learner = CorrectionLearner(fileURL: fileURL)
        learner.observe([candidate("teh", "the")], settings: settings)
        let ready = learner.observe([candidate("teh", "the")], settings: settings)
        learner.dismiss(ready[0])
        waitForPersist()

        let reloaded = CorrectionLearner(fileURL: fileURL)
        let again = reloaded.observe([candidate("teh", "the")], settings: settings)
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(reloaded.suggestions.first?.status, .dismissed)
    }

    func testExistingReplacementIsIgnored() {
        settings.replacements = [Replacement(pattern: "Teh", replacement: "the")]
        let learner = CorrectionLearner(fileURL: fileURL)
        for _ in 0..<3 {
            let ready = learner.observe([candidate("teh", "the")], settings: settings)
            XCTAssertTrue(ready.isEmpty)
        }
        XCTAssertTrue(learner.suggestions.isEmpty, "a standing rule already covers the pair")
    }

    func testAcceptCreatesLearnedReplacementAndDropsSuggestion() {
        let learner = CorrectionLearner(fileURL: fileURL)
        learner.observe([candidate("jon", "Jon")], settings: settings)
        let ready = learner.observe([candidate("jon", "Jon")], settings: settings)
        learner.accept(ready[0], settings: settings)

        XCTAssertEqual(settings.replacements.count, 1)
        XCTAssertEqual(settings.replacements.first?.pattern, "jon")
        XCTAssertEqual(settings.replacements.first?.replacement, "Jon")
        XCTAssertEqual(settings.replacements.first?.learned, true)
        XCTAssertTrue(learner.suggestions.isEmpty)
    }

    func testInverseRetirementRemovesLearnedButNotManualRules() {
        settings.replacements = [
            Replacement(pattern: "shelly", replacement: "Chellie", learned: true),
            Replacement(pattern: "sequel", replacement: "SQL"),   // manual
        ]
        let learner = CorrectionLearner(fileURL: fileURL)

        let remaining = learner.filteringInverses([
            candidate("Chellie", "shelly"),   // inverts the learned rule
            candidate("SQL", "sequel"),       // inverts the manual rule — untouchable
            candidate("jon", "Jon"),          // unrelated, passes through
        ], settings: settings)

        XCTAssertEqual(settings.replacements.count, 1, "learned rule retired")
        XCTAssertEqual(settings.replacements.first?.pattern, "sequel", "manual rule survives")
        XCTAssertEqual(remaining, [candidate("SQL", "sequel"), candidate("jon", "Jon")])

        // Both directions of the retired pair are dismissed for good.
        let ready = learner.observe([candidate("shelly", "Chellie"),
                                     candidate("Chellie", "shelly"),
                                     candidate("shelly", "Chellie"),
                                     candidate("Chellie", "shelly")], settings: settings)
        XCTAssertTrue(ready.isEmpty)
        XCTAssertTrue(learner.suggestions.allSatisfy { $0.status == .dismissed })
    }

    func testCorruptFileRecovery() throws {
        try Data("not json {{{".utf8).write(to: fileURL)
        let learner = CorrectionLearner(fileURL: fileURL)
        XCTAssertTrue(learner.suggestions.isEmpty)
        let bak = fileURL.appendingPathExtension("bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bak.path),
                      "corrupt data set aside, not destroyed")
    }

    func testPersistenceRoundTrip() {
        let learner = CorrectionLearner(fileURL: fileURL)
        learner.observe([candidate("jon", "Jon")], settings: settings)
        learner.observe([candidate("jon", "Jon"), candidate("teh", "the")], settings: settings)
        waitForPersist()

        let reloaded = CorrectionLearner(fileURL: fileURL)
        XCTAssertEqual(reloaded.suggestions, learner.suggestions)
        XCTAssertEqual(reloaded.readySuggestions.count, 1)
        XCTAssertEqual(reloaded.readySuggestions.first?.from, "jon")
    }

    func testCapDropsOldestPendingFirst() {
        let learner = CorrectionLearner(fileURL: fileURL)
        learner.observe([candidate("keeper", "Keeper")], settings: settings)
        learner.observe([candidate("keeper", "Keeper")], settings: settings)   // ready
        for i in 0..<CorrectionLearner.maxSuggestions {
            learner.observe([candidate("word\(i)", "Word\(i)")], settings: settings)
        }
        XCTAssertEqual(learner.suggestions.count, CorrectionLearner.maxSuggestions)
        XCTAssertEqual(learner.readySuggestions.first?.from, "keeper",
                       "ready suggestions outlive the pending flood")
        XCTAssertFalse(learner.suggestions.contains { $0.from == "word0" },
                       "the oldest pending pair was shed")
    }

    // async persist — same wait as HistoryStoreTests
    private func waitForPersist() {
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: fileURL.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
}

final class ReplacementDecodingTests: XCTestCase {
    func testLegacyPayloadWithoutLearnedDecodes() throws {
        // Persisted before `learned` existed — must decode, not wipe the list.
        let legacy = Data("""
        [{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","pattern":"sequel","replacement":"SQL"}]
        """.utf8)
        let decoded = try JSONDecoder().decode([Replacement].self, from: legacy)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].pattern, "sequel")
        XCTAssertEqual(decoded[0].replacement, "SQL")
        XCTAssertFalse(decoded[0].learned)
    }

    func testLearnedRoundTrips() throws {
        let rule = Replacement(pattern: "shelly", replacement: "Chellie", learned: true)
        let data = try JSONEncoder().encode([rule])
        let decoded = try JSONDecoder().decode([Replacement].self, from: data)
        XCTAssertEqual(decoded, [rule])
    }
}
