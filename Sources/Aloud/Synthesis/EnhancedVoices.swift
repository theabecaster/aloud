import Combine
import Foundation

// Getting Aloud's own voices onto the Mac, without ever asking.
//
// The rule this file exists to keep: a voice download is Aloud's errand, not
// the user's. Dictation already works this way — the speech model comes down in
// the background and basic dictation covers until it lands — and a voice is no
// different. So there is no Download button anywhere, no size quoted at
// somebody deciding, and no progress bar to watch. The picker says which voice
// is speaking today, and that is the whole of the user's involvement.
//
// While a voice is still arriving, `VoiceCatalog.resolved` hands back the best
// macOS voice on that side, which is exactly the degraded tier `speak` was
// designed around (docs §5, "the download is skippable"). Nothing is broken
// meanwhile; it just sounds like the Mac rather than like Aloud.
@MainActor
final class EnhancedVoices: ObservableObject {
    static let shared = EnhancedVoices()

    /// Which sides are being fetched right now. Published so the picker can
    /// say "using a basic voice for now" and stop saying it on its own.
    @Published private(set) var fetching: Set<VoiceGender> = []

    /// Which sides are loading the voice that will speak *now* — the models
    /// into memory and the first utterance through the compiler. Seconds, not
    /// minutes, and the only one of the two states that a control waits on:
    /// this is what turns the play button into a spinner.
    @Published private(set) var warming: Set<VoiceGender> = []

    /// Sides already loaded and compiled this session.
    private var warmed: Set<VoiceGender> = []

    /// Sides whose fetch failed this session. Not surfaced and not retried
    /// within the session — the next launch tries again, and the stand-in
    /// voice works the whole time. Same policy as the speech detector's
    /// catch-up: a failure the user can do nothing about is not news.
    private var failed: Set<VoiceGender> = []

    private init() {}

    /// Are this voice's assets on disk? Cheap enough to ask on a redraw.
    nonisolated static func isReady(_ option: VoiceOption) -> Bool {
        guard case .enhanced(let engine, _) = option.source else { return true }
        return engine.isDownloaded
    }

    /// Fetch what this side needs, if it isn't here and isn't already coming.
    /// Fire and forget: callers are announcing intent, not awaiting a result.
    func ensure(_ gender: VoiceGender) {
        guard let option = VoiceCatalog.enhancedVoice(for: gender),
              case .enhanced(let engine, let style) = option.source,
              !engine.isDownloaded,
              !fetching.contains(gender),
              !failed.contains(gender)
        else { return }

        fetching.insert(gender)
        Task { [weak self] in
            do {
                try await NeuralSpeaker(engine: engine, style: style).prepare()
                // The catalog's answer to "what speaks for this side" just
                // changed, and so has the speaker the pool should hand out.
                VoiceCatalog.refresh()
                self?.fetching.remove(gender)
                self?.warmed.remove(gender)
                self?.warm(gender)
            } catch {
                self?.fetching.remove(gender)
                self?.failed.insert(gender)
            }
        }
    }

    /// Load the voice that speaks for this side right now, and put one
    /// utterance through it. Called when a voice control appears and every
    /// time the user switches sides — the wait belongs there, where they have
    /// just said which voice they are about to want, rather than under the
    /// press that expects sound.
    ///
    /// The throwaway utterance is the point: loading the models is only half
    /// the cold cost, and the first synthesis is what compiles the CoreML
    /// variant for this chunk length. Paying it here is the difference between
    /// a press that speaks and a press that seems to have missed.
    func warm(_ gender: VoiceGender) {
        guard !warmed.contains(gender), !warming.contains(gender) else { return }
        let voice = SpeakerPool.speaker(for: VoiceCatalog.resolved(gender: gender))
        warming.insert(gender)
        Task { [weak self] in
            try? await voice.prepare()
            _ = try? await voice.synthesize(Self.warmupText)
            guard let self else { return }
            self.warmed.insert(gender)
            self.warming.remove(gender)
        }
    }

    /// Is this side ready to speak the instant it is asked?
    func isWarm(_ gender: VoiceGender) -> Bool { warmed.contains(gender) }

    // Never heard: what a voice says to itself so that the first thing it says
    // out loud is not the first thing it has ever synthesized. Short on
    // purpose — what is being paid here is the compile, not the words.
    private static let warmupText = "Hello."

    /// Everything the user could be about to hear. Called once setup is far
    /// enough along that the network is not being fought over — the voice is
    /// the least urgent thing Aloud downloads.
    func ensureAll() {
        for gender in VoiceGender.allCases { ensure(gender) }
    }
}
