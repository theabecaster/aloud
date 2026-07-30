import Foundation
import FluidAudio

// Biases recognition itself toward the user's Vocabulary replacements, so a
// name the model has never seen can win during decoding instead of relying on
// the post-transcription regex pass alone (which only fires when the model's
// misspelling happens to match the stored pattern).
//
// Mechanism (FluidAudio 0.15.x custom-vocabulary API): a small auxiliary CTC
// model scores the audio for each boosted term, and VocabularyRescorer swaps a
// transcript word for a term only when the term has genuinely higher acoustic
// evidence — replacements are verified against the audio, never guessed from
// spelling. Each replacement's target text is the boosted term; the pattern
// (what the model actually wrote) rides along as an alias, since it's an
// observed confusion for exactly this voice.
//
// The CTC models are a one-time ~100 MB download, fetched only once the user
// has created a replacement — the same model-download network exception the
// primary engine uses, to the same fixed host. Until they're ready (or if the
// download fails offline), rescore() quietly returns nil and dictation
// proceeds unboosted; the regex pass still guarantees exact-pattern fixes, so
// boosting can only ever add accuracy, never remove it.
actor VocabularyBooster {
    // Precision-first overrides of the SDK defaults, which are tuned to
    // maximize recall on keyword-spotting benchmarks (see the SDK's own
    // CustomVocabulary.md). A dictation app plants every false accept into
    // the user's document — misses are recoverable, fabrications are not.
    // -10 per-token spotter floor instead of the default -15 (the SDK's
    // documented lenient extreme); similarity floored at 0.6 (their >100-term
    // setting, strictest shipped); the flat acoustic head start capped at 3.
    private static let minSpotterScore: Float = -10.0
    private static let minTermSimilarity: Float = 0.6
    private static let maxBoost: Float = 3.0

    private var models: CtcModels?
    private var tokenizer: CtcTokenizer?
    private var spotter: CtcKeywordSpotter?
    private var rescorer: VocabularyRescorer?
    private var vocabulary: CustomVocabularyContext?

    // Terms the live rescorer was built for vs. the build currently underway.
    // A mismatch with the incoming terms schedules a rebuild; the in-flight
    // dictation goes unboosted rather than waiting on model work.
    private var builtTerms: [Replacement] = []
    private var targetTerms: [Replacement]?

    // Start loading models/terms ahead of the first dictation.
    func warm(terms: [Replacement]) {
        scheduleRebuild(for: usable(terms))
    }

    // Returns the rescored transcript, or nil when boosting changed nothing
    // (not ready, no terms, no acoustic match). Never throws: boosting is an
    // accuracy bonus and must not be able to fail a dictation.
    func rescore(text: String, tokenTimings: [TokenTiming], samples: [Float],
                 terms: [Replacement]) async -> String? {
        let terms = usable(terms)
        guard !terms.isEmpty, !text.isEmpty, !tokenTimings.isEmpty else { return nil }
        guard terms == builtTerms, let spotter, let rescorer, let vocabulary else {
            scheduleRebuild(for: terms)
            return nil
        }
        do {
            let spotted = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: samples, customVocabulary: vocabulary,
                minScore: Self.minSpotterScore)
            guard !spotted.logProbs.isEmpty else { return nil }
            let tuning = ContextBiasingConstants.rescorerConfig(forVocabSize: vocabulary.terms.count)
            // The SDK's size-based tuning maximizes recall on keyword-spotting
            // benchmarks; a dictation app plants every false accept into the
            // user's document, so precision wins: similarity is floored, the
            // flat acoustic head start capped.
            let output = rescorer.ctcTokenRescore(
                transcript: text,
                tokenTimings: tokenTimings,
                logProbs: spotted.logProbs,
                frameDuration: spotted.frameDuration,
                cbw: min(tuning.cbw, Self.maxBoost),
                minSimilarity: max(tuning.minSimilarity, Self.minTermSimilarity))
            guard output.wasModified else { return nil }
            // The acoustic score alone can misfire spectacularly — an
            // out-of-vocabulary name the model has never seen scores poorly
            // as itself and a boosted term wins by default, planting a
            // vocabulary word over something that sounds nothing like it.
            // Only accept a rescore whose every swap is textually plausible.
            guard Self.plausibleRescore(original: text, rescored: output.text,
                                        terms: terms) else { return nil }
            return output.text
        } catch {
            return nil
        }
    }

    // Boosting a one-letter term would be noise; the SDK skips terms under 3
    // characters anyway, so filter to what can actually take effect.
    private func usable(_ terms: [Replacement]) -> [Replacement] {
        terms.filter { $0.replacement.trimmingCharacters(in: .whitespaces).count >= 3 }
    }

    // A rescore is believed only when every word it swapped could actually be
    // confused, in writing, with the term that replaced it — either with the
    // term itself or with its alias, the misspelling this voice is known to
    // produce for it. Acoustic evidence proposes; text disposes. One
    // implausible swap rejects the whole rescore: a transcript that needed
    // that swap to happen was scored on the wrong footing throughout.
    static func plausibleRescore(original: String, rescored: String,
                                 terms: [Replacement]) -> Bool {
        let swaps = CorrectionDiff.candidates(original: original, corrected: rescored)
        for swap in swaps {
            guard let term = terms.first(where: {
                swap.to.range(of: $0.replacement, options: .caseInsensitive) != nil
            }) else { return false }   // changed something no term accounts for
            let from = swap.from.lowercased()
            let confusable = [term.replacement, term.pattern].contains { target in
                let t = target.lowercased()
                let allowed = max(2, min(from.count, t.count) / 3)
                return CorrectionGuess.editDistance(from, t, limit: allowed) != nil
            }
            guard confusable else { return false }
        }
        return true
    }

    private func scheduleRebuild(for terms: [Replacement]) {
        guard terms != builtTerms, terms != targetTerms else { return }
        targetTerms = terms
        guard !terms.isEmpty else {
            builtTerms = []
            spotter = nil; rescorer = nil; vocabulary = nil
            targetTerms = nil
            return
        }
        Task { await self.build(terms) }
    }

    private func build(_ terms: [Replacement]) async {
        guard terms == targetTerms else { return }   // superseded while queued
        do {
            // First call downloads; afterwards this is a local load.
            if models == nil { models = try await CtcModels.downloadAndLoad() }
            if tokenizer == nil {
                tokenizer = try await CtcTokenizer.load(from: CtcModels.defaultCacheDirectory())
            }
            guard let models, let tokenizer, terms == targetTerms else { return }
            let vocabTerms = terms.compactMap { r -> CustomVocabularyTerm? in
                let ids = tokenizer.encode(r.replacement)
                guard !ids.isEmpty else { return nil }
                return CustomVocabularyTerm(text: r.replacement, aliases: [r.pattern],
                                            ctcTokenIds: ids,
                                            minSimilarity: Self.minTermSimilarity)
            }
            guard !vocabTerms.isEmpty else { return }
            let vocab = CustomVocabularyContext(terms: vocabTerms)
            let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
            // The spotter-anchored acoustic rescue is the SDK's documented
            // dominant source of over-firing on small vocabularies — it
            // replaces text on acoustic score alone, no string similarity.
            // Off entirely: their measurements show ~5× fewer false accepts
            // at no recall cost on distinctive-name vocabularies, which is
            // exactly what user replacements are.
            let rescorer = try await VocabularyRescorer.create(
                spotter: spotter, vocabulary: vocab,
                config: VocabularyRescorer.Config(spotterRescueEnabled: false),
                ctcModelDirectory: CtcModels.defaultCacheDirectory())
            guard terms == targetTerms else { return }
            self.spotter = spotter
            self.rescorer = rescorer
            self.vocabulary = vocab
            self.builtTerms = terms
            self.targetTerms = nil
        } catch {
            // Likely offline before the one-time CTC download completed.
            // Clear the target so a later dictation retries the build.
            targetTerms = nil
        }
    }
}
