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

    func testFirstSightingAsksByDefault() {
        // A fix the user just made is worth asking about immediately; a "no"
        // is remembered forever, so an unwanted pair interrupts only once.
        let learner = CorrectionLearner(fileURL: fileURL)
        let first = learner.observe([candidate("jon", "Jon")], settings: settings)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.from, "jon")
        XCTAssertEqual(learner.readySuggestions.count, 1)

        // Already ready — a second sighting must not report it as newly ready.
        let second = learner.observe([candidate("jon", "Jon")], settings: settings)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(learner.readySuggestions.first?.count, 2)
    }

    func testThresholdPromotion() {
        let learner = CorrectionLearner(fileURL: fileURL)

        let first = learner.observe([candidate("jon", "Jon")], settings: settings, threshold: 2)
        XCTAssertTrue(first.isEmpty, "one sighting is not a pattern at this threshold")
        XCTAssertEqual(learner.suggestions.first?.status, .pending)
        XCTAssertTrue(learner.readySuggestions.isEmpty)

        let second = learner.observe([candidate("jon", "Jon")], settings: settings, threshold: 2)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.from, "jon")
        XCTAssertEqual(second.first?.to, "Jon")
        XCTAssertEqual(learner.readySuggestions.count, 1)
        XCTAssertEqual(learner.readySuggestions.first?.count, 2)

        let third = learner.observe([candidate("jon", "Jon")], settings: settings, threshold: 2)
        XCTAssertTrue(third.isEmpty)
        XCTAssertEqual(learner.readySuggestions.first?.count, 3)
    }

    func testMatchIsCaseInsensitiveAndToClampsToLatest() {
        let learner = CorrectionLearner(fileURL: fileURL)
        let ready = learner.observe([candidate("shelly", "Chellie")], settings: settings)
        XCTAssertEqual(ready.count, 1)
        learner.observe([candidate("Shelly", "chellie")], settings: settings)
        XCTAssertEqual(learner.readySuggestions.count, 1,
                       "case-different from counts toward the same pair")
        XCTAssertEqual(learner.readySuggestions.first?.to, "chellie",
                       "latest observed spelling wins")
    }

    func testDismissIsSticky() {
        let learner = CorrectionLearner(fileURL: fileURL)
        let ready = learner.observe([candidate("teh", "the")], settings: settings)
        learner.dismiss(ready[0])
        XCTAssertTrue(learner.readySuggestions.isEmpty)

        for _ in 0..<5 {
            let again = learner.observe([candidate("teh", "the")], settings: settings)
            XCTAssertTrue(again.isEmpty, "a dismissed pair never comes back")
        }
        XCTAssertTrue(learner.readySuggestions.isEmpty)
        XCTAssertEqual(learner.suggestions.first?.count, 1, "counting stopped at dismissal")
    }

    func testDismissSurvivesReload() {
        let learner = CorrectionLearner(fileURL: fileURL)
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

    func testStyleRewritesAreNotPassiveCandidates() {
        // "meeting" → "call" is the user writing, not the user respelling
        // what was heard; only confusable pairs survive.
        let found = CorrectionLearner.passiveCandidates(
            original: "set up a meeting with John Smith",
            corrected: "set up a call with John Smyth")
        XCTAssertEqual(found, [CorrectionDiff.Candidate(from: "Smith", to: "Smyth")])
    }

    func testStalePendingPairsDecayAway() throws {
        // A pending pair last seen beyond the lifetime is forgotten by the
        // next observation pass — a month-old stray edit can't pair with one
        // today. Seed the store on disk the way persistence writes it.
        let old = Date(timeIntervalSinceNow: -CorrectionLearner.pendingLifetime - 60)
        let stale = CorrectionLearner.Suggestion(id: UUID(), from: "stale", to: "stail",
                                                 count: 1, firstSeen: old, lastSeen: old,
                                                 status: .pending)
        try JSONEncoder().encode([stale]).write(to: fileURL)
        let learner = CorrectionLearner(fileURL: fileURL)
        learner.observe([candidate("other", "othr")], settings: settings)
        XCTAssertFalse(learner.suggestions.contains { $0.from == "stale" })
        // A fresh sighting after decay starts the count over.
        let ready = learner.observe([candidate("stale", "stail")], settings: settings)
        XCTAssertEqual(ready.count, 1, "forgotten, so it reads as a first sighting")
        XCTAssertEqual(learner.suggestions.first { $0.from == "stale" }?.count, 1)
    }

    func testCorrectingARuleOutputIsNeverANewRule() {
        // "DentAI" on screen came from the user's own vocabulary rule; the
        // user changing it means that rule (or the booster) misfired — a
        // suggestion to rewrite DentAI would corrupt every legitimate use.
        settings.replacements = [Replacement(pattern: "Dente Eye", replacement: "DentAI")]
        let learner = CorrectionLearner(fileURL: fileURL)
        for _ in 0..<3 {
            let ready = learner.observe([candidate("DentAI", "Smyth")], settings: settings)
            XCTAssertTrue(ready.isEmpty)
        }
        XCTAssertTrue(learner.suggestions.isEmpty)
    }

    func testAcceptCreatesLearnedReplacementAndDropsSuggestion() {
        let learner = CorrectionLearner(fileURL: fileURL)
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
        XCTAssertEqual(reloaded.readySuggestions.count, 2)
        XCTAssertEqual(Set(reloaded.readySuggestions.map(\.from)), ["jon", "teh"])
    }

    func testCapDropsOldestPendingFirst() {
        let learner = CorrectionLearner(fileURL: fileURL)
        learner.observe([candidate("keeper", "Keeper")], settings: settings)   // ready
        for i in 0..<CorrectionLearner.maxSuggestions {
            learner.observe([candidate("word\(i)", "Word\(i)")], settings: settings, threshold: 2)
        }
        XCTAssertEqual(learner.suggestions.count, CorrectionLearner.maxSuggestions)
        XCTAssertEqual(learner.readySuggestions.first?.from, "keeper",
                       "ready suggestions outlive the pending flood")
        XCTAssertFalse(learner.suggestions.contains { $0.from == "word0" },
                       "the oldest pending pair was shed")
    }

    func testResetDismissalsForgetsOnlyMatchingDismissedPairs() {
        let learner = CorrectionLearner(fileURL: fileURL)
        learner.observe([candidate("jon", "Jon"), candidate("acme", "ACME")], settings: settings)
        for ready in learner.readySuggestions { learner.dismiss(ready) }
        learner.observe([candidate("bob", "Bob")], settings: settings)

        // Case-insensitive on the pattern, like every other `from` match.
        learner.resetDismissals(matchingPattern: "JON")

        XCTAssertFalse(learner.suggestions.contains { $0.from == "jon" },
                       "the matching dismissal is forgotten")
        XCTAssertEqual(learner.suggestions.first { $0.from == "acme" }?.status, .dismissed,
                       "an unrelated dismissal stays dismissed")
        XCTAssertEqual(learner.suggestions.first { $0.from == "bob" }?.status, .ready,
                       "a live pair with a different pattern is untouched")

        // A pattern matching only non-dismissed pairs removes nothing.
        learner.resetDismissals(matchingPattern: "bob")
        XCTAssertEqual(learner.suggestions.first { $0.from == "bob" }?.status, .ready)

        // The removal survives a reload.
        waitForPersist()
        let reloaded = CorrectionLearner(fileURL: fileURL)
        XCTAssertFalse(reloaded.suggestions.contains { $0.from == "jon" })
        XCTAssertEqual(reloaded.suggestions.first { $0.from == "acme" }?.status, .dismissed)
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
