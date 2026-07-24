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
                audioSamples: samples, customVocabulary: vocabulary, minScore: nil)
            guard !spotted.logProbs.isEmpty else { return nil }
            let tuning = ContextBiasingConstants.rescorerConfig(forVocabSize: vocabulary.terms.count)
            let output = rescorer.ctcTokenRescore(
                transcript: text,
                tokenTimings: tokenTimings,
                logProbs: spotted.logProbs,
                frameDuration: spotted.frameDuration,
                cbw: tuning.cbw,
                minSimilarity: tuning.minSimilarity)
            return output.wasModified ? output.text : nil
        } catch {
            return nil
        }
    }

    // Boosting a one-letter term would be noise; the SDK skips terms under 3
    // characters anyway, so filter to what can actually take effect.
    private func usable(_ terms: [Replacement]) -> [Replacement] {
        terms.filter { $0.replacement.trimmingCharacters(in: .whitespaces).count >= 3 }
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
                                            ctcTokenIds: ids)
            }
            guard !vocabTerms.isEmpty else { return }
            let vocab = CustomVocabularyContext(terms: vocabTerms)
            let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
            let rescorer = try await VocabularyRescorer.create(
                spotter: spotter, vocabulary: vocab,
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
