import AppKit
import SwiftUI

// The small floating "I'm listening" pill: a non-activating panel near the
// bottom-center of the active screen, visible on all Spaces, never steals focus.
// Shows a live level meter while recording, a spinner while transcribing, and
// short hint messages. Subtle fade/scale in and out.
@MainActor
final class RecordingIndicatorPanel {
    private var panel: NSPanel?
    private let model = IndicatorModel()

    // What the pill is showing right now. Read-only, and only so tests can
    // assert on the phase — which is where a completed turn's tick lives, and
    // which nothing could see from outside when it was being silently wiped.
    var agentPhaseForTesting: AgentIndicatorPhase { model.agentPhase }
    private var levelTimer: Timer?
    // Bumped by present() and hide() so a pending or in-flight hide can tell
    // whether a show snuck in behind it (hands-free is a cancel immediately
    // followed by a re-show) and must leave the panel alone.
    private var hideGeneration = 0
    // Same idea for hint auto-dismissal, so a second hint can't be cut short
    // by the first one's timer.
    private var hintGeneration = 0
    // Logically on screen: present() called, no hide committed yet.
    private var isShowing = false
    private var isFadingOut = false
    private var shownAt: TimeInterval = 0
    private static let fadeDuration: TimeInterval = 0.18
    // A pill that just appeared holds still this long before it may fade out.
    // Arming hands-free is a short tap (cancel → hide) followed by a second
    // press up to a double-tap window later (begin → show); without this floor
    // the pill blinks out and back in mid-gesture and reads as a glitch. Any
    // session long enough to be real has already outlived it.
    private static let minimumVisible: TimeInterval = 0.6
    // The window the pill floats in. Taller than the pill itself so the noise
    // badge can sit proud of its top corner without the window edge cutting
    // through it; the pill stays vertically centred, so the extra height is
    // invisible. Defined once because it is set in two places, and when those
    // two drifted apart the reposition quietly squashed the badge flat.
    static let panelSize = NSSize(width: 280, height: 80)
    // The same window with room above for the "an agent wants to speak" bubble.
    // Its 80 points leave about twenty above a centred pill — enough for the
    // noise badge sitting proud of a corner, and not nearly enough for two
    // lines of text, which the window edge simply cut in half. The pill stays
    // centred, so the extra height costs nothing when the bubble is absent
    // because the window is only ever the space the pill floats in.
    static let panelSizeWithAgentWaiting = NSSize(width: 280, height: 210)
    // How far above the pill the bubble sits. Its own height plus a gap the
    // size of the chat panel's, so the two read as the same kind of thing
    // opening out of the same pill — and so the alert ring has somewhere to
    // travel that is not on top of the indicator the user is busy with.
    static let agentWaitingGap: CGFloat = 46
    // The agent variant's pill is the same size as the dictation one, but the
    // chat panel opens upward out of it (AgentChatPanel) and has to have
    // somewhere to open into. Same reasoning as above — the window is only the
    // space the pill floats in, and the pill stays centred in it — so the
    // headroom is bought by making the window tall and letting the empty half
    // below hang off the bottom of the screen, which costs nothing: it is
    // transparent, and nothing in it hit-tests.
    static let agentPanelSize = NSSize(width: 420, height: 940)
    // The tallest the chat panel can get, gap included — its own maximum thread
    // (240) plus a full-height draft (130) plus padding and the composer's
    // chrome. The window above has to hold this on either side of the pill,
    // because the panel opens upward normally and downward when the pill is
    // parked near the top of the screen; half of 940 minus the pill's own
    // height clears it with room to spare. Getting this wrong does not error —
    // it silently clips the oldest messages against the window edge.
    static let agentPanelReach: CGFloat = 450
    // Hands-free silence reminder ("Still listening…", rule in SilenceReminder
    // below). These two track it when no speech detector is available: the
    // input level that counts as a voice, and when it was last cleared.
    private static let voiceLevel: Float = 0.1
    private var lastVoiceTime: TimeInterval = 0
    // When the session was locked.
    private var lockedAt: TimeInterval = 0

    // Seconds since the mic last heard actual speech, when a speech detector
    // is running. nil falls back to the input-level threshold below — which is
    // the reason this exists: a room with a fan, a café, or a nearby
    // conversation clears that threshold on its own, so the reminder that's
    // supposed to catch a session left running never fired anywhere noisy.
    var speechAgeProvider: (() -> TimeInterval?)?

    // Fires when the close button on the locked pill is clicked.
    var onStopHandsFree: (() -> Void)? {
        get { model.onStop }
        set { model.onStop = newValue }
    }

    // Fires as a hands-free or command pill leaves the screen — however it
    // ended: committed, cancelled, stopped from the pill, or reaped. The pill
    // vanishing is the whole of the "it's over" signal for a session the user
    // isn't holding a key for, so the controller sounds it.
    var onHandsFreeEnd: (() -> Void)?

    // The noise-filtering badge on the pill: its state, and what a click does.
    var noiseReduction: Bool {
        get { model.noiseReduction }
        set { model.noiseReduction = newValue }
    }
    var onToggleNoiseReduction: (() -> Void)? {
        get { model.onToggleNoiseReduction }
        set { model.onToggleNoiseReduction = newValue }
    }
    // Rebuilding capture for a filter flip takes a moment. The badge shows a
    // spinner for that stretch instead of pretending the flip already
    // landed, and ignores presses until it has.
    var noiseBusy: Bool {
        get { model.noiseBusy }
        set { model.noiseBusy = newValue }
    }
    // Whether the audio route allows filtering at all (headphones as the
    // output make it unavailable). Off: the quick menu's toggle dims, and
    // the badge never shows — nothing may claim a filter that cannot run.
    var noiseReductionAvailable: Bool {
        get { model.noiseReductionAvailable }
        set { model.noiseReductionAvailable = newValue }
    }

    // Settings drive the quick menu (mic, clean-up) and remember where the
    // user dragged the pill.
    var settings: SettingsStore? {
        get { model.settings }
        set { model.settings = newValue }
    }

    var levelsProvider: (() -> [PolishLevel])? {
        get { model.levelsProvider }
        set { model.levelsProvider = newValue }
    }

    // True while we set the frame ourselves, so the didMove observer only
    // records user drags.
    private var isRepositioning = false
    private var moveObserver: NSObjectProtocol?

    // Basic dictation (fallback engine) in use: the pill carries a small tag
    // so it's always visible when a session runs at reduced accuracy.
    var isBasic: Bool {
        get { model.isBasic }
        set { model.isBasic = newValue }
    }

    // `command: true` marks a command hold — same live meter, purple styling,
    // so "talking to the app" never looks like "typing into the document".
    // `warming: true` is the pill going up on the key down, before the engine
    // has opened the microphone; the same call without it, from the start
    // callback, is what says the mic is live.
    func show(levelProvider: @escaping () -> Float,
              bandsProvider: (() -> [Float])? = nil,
              command: Bool = false,
              warming: Bool = false) {
        announceTask?.cancel()
        model.mode = .recording
        model.hint = nil
        model.isLocked = false
        model.isCommand = command
        model.isWarming = warming
        model.stillListening = false
        model.notice = nil   // never carry a previous session's note into this one
        model.level = 0
        model.bands = SpectrumAnalyzer.silent
        // Back to the dictation window. A user dictation can start while an
        // agent pill is still on screen (its wrap-up beat), and the agent
        // window is 420×940 of mouse-opaque space around a 280×80 pill — the
        // pill looks right either way, but everything under that rectangle
        // stops taking clicks until the next show-from-hidden.
        applyPanelSize()
        present()
        // While recording the pill takes mouse input so it can be dragged to
        // a better spot and right-clicked for the quick menu. The transient
        // states below stay click-through.
        panel?.ignoresMouseEvents = false
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            let level = levelProvider()
            // No spectrum available (a caller that only has a level): every bar
            // follows the one number, which is the old meter's behaviour.
            let bands = bandsProvider?() ?? [Float](repeating: level, count: SpectrumAnalyzer.bandCount)
            Task { @MainActor in
                guard let self else { return }
                // Fast attack, slow release: raw RMS jitters frame to frame and
                // a bare threshold made the leading bars strobe. Rising edges
                // stay instant so the meter still feels live.
                self.model.level = level > self.model.level
                    ? level
                    : self.model.level + (level - self.model.level) * 0.25
                // Same curve per band — audio arrives in chunks slower than
                // this timer, so without it the bars would step, not move.
                self.model.bands = Self.smooth(self.model.bands, toward: bands)
                self.updateStillListening(level: level)
            }
        }
    }

    private static func smooth(_ current: [Float], toward target: [Float]) -> [Float] {
        guard current.count == target.count else { return target }
        return zip(current, target).map { now, next in
            next > now ? next : now + (next - now) * 0.28
        }
    }

    // Whether the pill currently wears the hands-free lock. The controller
    // reads this across its async session start: a lock that arrived while
    // the engine was still spinning up must survive the flip from "Getting
    // ready…" to the live meter. For that read to mean "locked during the
    // session now starting", the flag has to be cleared when one begins —
    // hiding the pill leaves it set, and a stale one would carry the lock's
    // orange mic and stop button onto the next ordinary push-to-talk.
    var isHandsFreeLocked: Bool { model.isLocked }

    func clearHandsFreeLock() {
        model.isLocked = false
    }

    // Hands-free lock engaged: keep the live meter, add the lock affordance.
    // Only the locked pill takes mouse input (for its close button) — everywhere
    // else the panel stays click-through so it can never swallow a stray click.
    func showLocked() {
        model.isLocked = true
        panel?.ignoresMouseEvents = false
        lastVoiceTime = ProcessInfo.processInfo.systemUptime
        lockedAt = lastVoiceTime
    }

    // The reminder latches: it appears once the session has been silent long
    // enough while the user is away from the keyboard, and then only speech
    // takes it back down. Recomputing it every frame let a single mouse twitch
    // swap the caption for the meter and back — a 30 Hz flicker on an otherwise
    // static pill.
    private func updateStillListening(level: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        let silentFor: TimeInterval
        if let age = speechAgeProvider?() {
            silentFor = age
        } else {
            if level > Self.voiceLevel { lastVoiceTime = now }
            silentFor = now - lastVoiceTime
        }
        let wasShowing = model.stillListening
        model.stillListening = SilenceReminder.next(
            showing: wasShowing,
            silentFor: silentFor,
            lockedFor: now - lockedAt,
            isLocked: model.isLocked,
            // System-wide input idle: typing or mousing means the user is
            // engaged, not absent — hold the reminder back. Read lazily; it's
            // three syscalls that only matter at the moment of the decision.
            inputIdle: {
                min(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown),
                    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown),
                    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved))
            })
        // The reminder exists because the user's eyes are elsewhere — a
        // pill quietly swapping its caption may never be seen at all. One
        // gentle sound at the moment it latches; the latch itself keeps it
        // from repeating until speech resets it.
        // The sound is for the user who is away from the screen; the wobble is
        // for the one who is at it but looking somewhere else on it. A caption
        // swapping in place is easy to miss in peripheral vision — movement
        // isn't, which is the whole of what peripheral vision is good at.
        if model.stillListening, !wasShowing {
            onStillListening?()
            model.nudge += 1
        }
    }

    // Fires once each time the still-listening reminder appears.
    var onStillListening: (() -> Void)?

    // Timings live on the panel; the rule itself is here so it can be tested
    // without an AppKit window or a 30 Hz timer.
    enum SilenceReminder {
        static let showAfter: TimeInterval = 30
        static let inputIdleGrace: TimeInterval = 6
        static let recentSpeechWindow: TimeInterval = 0.5

        // `silentFor` is seconds since speech, `lockedFor` seconds since the
        // session was locked — the reminder waits out both, so locking a
        // session that had already gone quiet still gets its full thirty
        // seconds rather than an instant nudge.
        static func next(showing: Bool,
                         silentFor: TimeInterval,
                         lockedFor: TimeInterval,
                         isLocked: Bool,
                         inputIdle: () -> TimeInterval) -> Bool {
            guard silentFor >= recentSpeechWindow, isLocked else { return false }
            guard !showing else { return true }
            let quietFor = min(silentFor, lockedFor)
            guard quietFor > showAfter else { return false }
            return inputIdle() > inputIdleGrace
        }
    }

    // Brief note inside a live recording pill (e.g. mic switched) — the meter
    // comes right back; unlike showHint this never leaves recording mode.
    func showNotice(_ text: String) {
        guard model.mode == .recording else { return }
        model.notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.model.notice == text { self?.model.notice = nil }
        }
    }

    // "Typing…"/"Working…" get the same forgiveness as "Getting ready…": a
    // commit that lands fast never flashes them. With no explicit caption the
    // pill keeps its meter for a beat — draining toward silence, so it still
    // reads as alive — and the spinner appears only if the model is genuinely
    // still at work. An explicit caption ("Getting ready…", "Polishing…")
    // shows at once: its caller already waited out a grace of its own. Any
    // later state change cancels the pending flip.
    private static let announceGrace: Duration = .milliseconds(300)
    private var announceTask: Task<Void, Never>?

    func showTranscribing(label: String? = nil) {
        announceTask?.cancel()
        // Only a live meter is worth holding on to; a hidden pill (a retry
        // from the menu) shows its feedback immediately instead.
        guard label == nil, model.mode == .recording, isShowing else {
            applyTranscribing(label: label, command: false)
            return
        }
        announceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.announceGrace)
            guard !Task.isCancelled else { return }
            self?.applyTranscribing(label: nil, command: false)
        }
    }

    // Command twin of showTranscribing: the model is thinking, not typing yet.
    func showWorking() {
        announceTask?.cancel()
        guard model.mode == .recording, isShowing else {
            applyTranscribing(label: nil, command: true)
            return
        }
        announceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.announceGrace)
            guard !Task.isCancelled else { return }
            self?.applyTranscribing(label: nil, command: true)
        }
    }

    private func applyTranscribing(label: String?, command: Bool) {
        levelTimer?.invalidate()
        model.mode = .transcribing
        applyPanelSize()
        model.isCommand = command
        model.isWarming = false
        model.transcribingLabel = label
        present()
        panel?.ignoresMouseEvents = true
    }

    // MARK: an agent waiting on the user's own dictation
    //
    // Kept alive rather than switched on: the service calls this repeatedly for
    // as long as it is waiting, and the badge takes itself down shortly after
    // the calls stop. An agent that crashes mid-wait therefore cannot leave a
    // notice on the user's pill for the rest of the session, which a plain
    // on/off flag would depend on somebody remembering to clear.
    private var agentWaitingGeneration = 0
    private static let agentWaitingLinger: TimeInterval = 4

    // Whether the notice is already up, so the caller can sound its cue once
    // for a wait rather than on every keep-alive tick.
    var isShowingAgentWaiting: Bool { model.agentWaiting }

    func noteAgentWaiting() {
        if !model.agentWaiting {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                model.agentWaiting = true
            }
            // The window has to grow before the bubble is drawn into it, or the
            // edge cuts the text in half — which is exactly how this shipped
            // the first time.
            applyPanelSize()
        }
        agentWaitingGeneration += 1
        let generation = agentWaitingGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.agentWaitingLinger) { [weak self] in
            guard let self, self.agentWaitingGeneration == generation else { return }
            self.clearAgentWaiting()
        }
    }

    func clearAgentWaiting() {
        agentWaitingGeneration += 1
        guard model.agentWaiting else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
            model.agentWaiting = false
        }
        applyPanelSize()
    }

    func showHint(_ text: String) {
        announceTask?.cancel()
        levelTimer?.invalidate()
        levelTimer = nil
        model.mode = .hint
        applyPanelSize()
        model.hint = text
        model.notice = nil
        model.stillListening = false
        present()
        panel?.ignoresMouseEvents = true
        hintGeneration += 1
        let generation = hintGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, self.hintGeneration == generation, self.model.mode == .hint else { return }
            self.hide()
        }
    }

    // MARK: - agent sessions (docs/agent-voice-bridge.md §7.1d)

    // An agent session is on screen. Calling it again is how the phase moves —
    // the transcript, the consent controls and the meter survive, because the
    // pill is one session's worth of state, not one message's.
    //
    // The meter providers are optional: pass them once when capture starts and
    // leave them off for later phase changes.
    func showAgentSession(session: String?,
                          harness: String? = nil,
                          lease: String? = nil,
                          phase: AgentIndicatorPhase = .listening,
                          levelProvider: (() -> Float)? = nil,
                          bandsProvider: (() -> [Float])? = nil) {
        announceTask?.cancel()
        // A session that is still going cancels its own wrap-up, for the same
        // reason `agentSaid` does.
        cancelPendingDismiss()
        enterAgentMode(lease: lease)
        model.agentPhase = phase
        model.agentCaller = callerLabel(session)
        model.agentHarness = callerLabel(harness)
        present()
        // Agent pills are clickable throughout — the accept/deny controls can
        // appear at any point in the session, and a pill that only started
        // taking clicks at that moment would drop the first one.
        panel?.ignoresMouseEvents = false
        guard let levelProvider else { return }
        attachMeter(levelProvider: levelProvider, bandsProvider: bandsProvider)
    }

    // Start the meter on a pill that is already up. Confirm-by-voice needs it:
    // the question is shown first and the microphone opens only once the spoken
    // prompt has finished playing, so there is nothing to meter at show time.
    // Without this the pill renders a resting meter under a question that is
    // waiting on the user's voice — which is indistinguishable from a
    // microphone that never opened, and that is a failure this feature has
    // already had. A dead meter must mean a dead microphone.
    func attachMeter(levelProvider: @escaping () -> Float,
                     bandsProvider: (() -> [Float])? = nil,
                     micIsLive: Bool = true,
                     playingProvider: (() -> Bool)? = nil) {
        model.micIsLive = micIsLive
        model.voiceIsPlaying = playingProvider?() ?? true
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            let level = levelProvider()
            let bands = bandsProvider?() ?? [Float](repeating: level, count: SpectrumAnalyzer.bandCount)
            let playing = playingProvider?()
            Task { @MainActor in
                guard let self else { return }
                self.model.level = level > self.model.level
                    ? level
                    : self.model.level + (level - self.model.level) * 0.25
                self.model.bands = Self.smooth(self.model.bands, toward: bands)
                if let playing { self.model.voiceIsPlaying = playing }
            }
        }
    }

    // The phase alone, for a session that is already up.
    func updateAgentPhase(_ phase: AgentIndicatorPhase) {
        model.agentPhase = phase
    }

    func setMicIsLive(_ live: Bool) {
        model.micIsLive = live
    }

    // MARK: the chat panel (AgentChatPanel)

    // What the agent said, out loud, as a message in the thread. Shown as the
    // agent's own bubble on the left — and only ever the final, concise thing
    // it chose to say, which is what reaches the speakers anyway.
    func agentSaid(_ text: String, lease: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The exchange is still going, so the wrap-up the last send scheduled
        // no longer describes it. Without this the panel closed on its timer
        // between two turns and the next question opened it again from nothing
        // — one conversation, played as two.
        cancelPendingDismiss()
        adoptThread(lease: lease)
        // One thing at a time when the session is brand new.
        //
        // The pill and the panel arriving together read as a single slab
        // landing on the screen, which is the opposite of what the panel's own
        // reveal is drawn to do — it wipes open out of the pill, and that only
        // means anything if the pill is already there to open out of. So on a
        // session that has just appeared, the words wait a beat for the pill to
        // settle; mid-conversation there is nothing to wait for and the message
        // goes up immediately.
        let justAppeared = ProcessInfo.processInfo.systemUptime - shownAt < Self.pillSettle
        guard justAppeared, !model.chatIsOpen else {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) {
                model.appendChatMessage(author: .agent, text: trimmed)
                model.chatIsOpen = true
            }
            return
        }
        let generation = sendGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pillSettle) { [weak self] in
            guard let self, self.sendGeneration == generation, self.model.mode == .agent else { return }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) {
                self.model.appendChatMessage(author: .agent, text: trimmed)
                self.model.chatIsOpen = true
            }
        }
    }

    // How long the pill is given to arrive before the panel opens out of it.
    // Short enough to read as one gesture in two parts rather than as a wait.
    private static let pillSettle: TimeInterval = 0.26

    // Whether the pill arrived just now, for callers that should let it land
    // before doing the next thing — the agent starting to talk over its own
    // indicator still fading in reads as the app tripping over itself.
    var pillJustAppeared: Bool {
        ProcessInfo.processInfo.systemUptime - shownAt < Self.pillSettle
    }

    // Whatever this session had queued up to close itself with, it isn't
    // closing: the generation moves on and the pending timer bails.
    private func cancelPendingDismiss() {
        sendGeneration += 1
    }

    // What has been heard so far, in full — the draft the user is composing by
    // speaking. Deliberately ungated: a first partial that arrives a beat
    // before the session is shown is kept rather than dropped, and entering a
    // new session clears whatever the last one left behind.
    func updateTranscript(_ text: String) {
        model.chatDraft = text
        model.agentTranscript = text
    }

    // The microphone is open: the draft field appears (empty, with its "go
    // ahead" placeholder) so there is somewhere for the words to land before
    // any have arrived.
    func openDraft() {
        cancelPendingDismiss()
        // The composer is about to reclaim the send identity, so the bubble
        // that had it gives it up: two live views holding one geometry id is
        // undefined, and the symptom is a bubble that jumps to the field.
        model.lastSentMessageID = nil
        model.chatDraft = ""
        // Animated, so the panel grows into the draft field rather than
        // snapping a taller box into place under the conversation.
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            model.chatDraftIsVisible = true
            model.chatIsOpen = true
        }
    }

    // The turn has ended and the words are being settled — the batch
    // transcription and, where this Mac can do it, the rewrite. Deliberately
    // NOT `showTranscribing`: that is the dictation pill's spinner, and using it
    // here dropped the whole agent variant on the floor mid-turn. The panel
    // vanished, the pill said "Typing…" (into what? an agent session types
    // nothing), and the draft the user had just watched themselves compose was
    // never seen being sent. The conversation stays exactly where it was; only
    // the microphone closes and the send button becomes a spinner.
    func settleDraft() {
        model.micIsLive = false
        withAnimation(.easeOut(duration: 0.2)) { model.chatIsSettling = true }
    }

    // MARK: showing the rewrite happen
    //
    // What the user said, then what is actually being sent, then how much
    // shorter that made it.
    //
    // The rewrite was previously invisible: the spinner resolved straight into
    // a bubble holding text the user had not watched appear, so the one thing
    // Aloud does between hearing them and answering — condense it — happened
    // where nobody could see it. Showing the verbatim line first and letting it
    // become the concise one makes the work legible, and the count that flies
    // off says what it bought.
    private var savingGeneration = 0

    // Roughly four characters to a token. Deliberately approximate: this is a
    // flourish, and a number that looked precise would be claiming an accuracy
    // no character count has.
    static func estimatedTokens(_ text: String) -> Int {
        Int((Double(text.count) / 4).rounded())
    }

    static func tokensSaved(from raw: String, to concise: String) -> Int {
        max(0, estimatedTokens(raw) - estimatedTokens(concise))
    }

    // How long the verbatim line is left up before it condenses. Long enough to
    // register as words, short enough that it is not a wait.
    private static let verbatimBeat = Duration.milliseconds(540)
    // How long the condensed line stands before it is sent. Longer when there
    // is a count climbing off it: the send takes the composer with it, and a
    // number cut off mid-flight is one the user saw but could not read — which
    // was the first version's whole problem.
    private static let settleBeat = Duration.milliseconds(460)
    private static let settleBeatWithCoin = Duration.milliseconds(1250)
    // Comfortably past the rise-and-fade in `TokenSavingCoin`, so the view is
    // never torn out from under its own animation.
    private static let coinFlight = Duration.milliseconds(1900)

    func revealConcise(raw: String, concise: String) async {
        let verbatim = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = concise.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty else { return }

        // Out of the spinner and into the words, whichever way this goes.
        withAnimation(.easeOut(duration: 0.22)) {
            model.chatIsSettling = false
            model.chatDraftIsVisible = true
            model.chatDraft = verbatim.isEmpty ? final : verbatim
        }
        // Nothing was rewritten — this Mac has no Concise tier, or the sentence
        // was already as short as it gets. There is no transformation to show
        // and no saving to claim, so the draft simply stands as it is.
        guard !verbatim.isEmpty, verbatim != final else { return }

        try? await Task.sleep(for: Self.verbatimBeat)
        withAnimation(.spring(response: 0.44, dampingFraction: 0.82)) {
            model.chatDraft = final
        }

        // Only when the rewrite actually bought something. A "0 tokens" badge
        // is a claim of value where there was none, and a negative one — the
        // rewrite came out longer, which happens — would be advertising a loss.
        let saved = Self.tokensSaved(from: verbatim, to: final)
        if saved > 0 {
            savingGeneration += 1
            let generation = savingGeneration
            model.tokenSaving = IndicatorModel.TokenSaving(
                id: generation,
                tokens: saved,
                drift: CGFloat.random(in: -26...26))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.coinFlight)
                guard let self, self.model.tokenSaving?.id == generation else { return }
                self.model.tokenSaving = nil
            }
        }
        try? await Task.sleep(for: saved > 0 ? Self.settleBeatWithCoin : Self.settleBeat)
    }

    // The turn ended and this is the text the agent actually receives. The draft
    // is sent: the field flies up, the message lands in the thread as the user's
    // own bubble on the right, and after a beat the whole thing — panel and pill
    // together — wraps up and goes. That beat is not decoration; it is the only
    // moment the user can check that what left in their name is what they said.
    func sendDraft(_ finalText: String, dismissAfter: TimeInterval = 3.5) {
        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return dismissChat(after: 0) }
        model.chatIsOpen = true
        sendGeneration += 1
        let generation = sendGeneration
        // Appended NOW, not after the send animation. The agent is handed the
        // transcript the instant this call returns and often speaks again
        // within a few hundred milliseconds — so a bubble that waited for the
        // animation landed *after* the next question, and the thread read
        // question, question, answer. The order of a conversation is not a
        // detail the animation gets to decide.
        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
            model.chatIsSending = true
            model.appendChatMessage(author: .user, text: trimmed)
            model.chatDraft = ""
            model.chatDraftIsVisible = false
            model.chatIsSettling = false
            // Inside the same update as the rest of the send. Set after it, the
            // settling spinner had already been taken down while the phase was
            // still `.listening`, and the pill rendered one frame of the
            // closed-microphone spinner on the way to the tick.
            model.agentPhase = .done
            model.micIsLive = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.sendGeneration == generation else { return }
            self.model.chatIsSending = false
        }
        dismissChat(after: dismissAfter, generation: generation)
    }

    // A speak that may be followed straight away by a listen. Hiding the moment
    // playback stopped tore the whole thing down — pill and panel faded out, and
    // the listen a few hundred milliseconds later faded them back in around the
    // same conversation. What is actually happening is one continuous exchange,
    // so it should look like one: the teardown waits, and a listen arriving
    // inside that window cancels it (every `present()` bumps the generation).
    func hideAfterAgentSpeech(delay: TimeInterval = 1.4) {
        hideGeneration += 1
        let generation = hideGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.hideGeneration == generation else { return }
            self.hide()
        }
    }

    // Bumped by every send so a dismissal scheduled by one turn can tell it no
    // longer describes the session — the same lease asking a second question
    // inside the beat must keep its thread on screen, not have it swept by the
    // first turn's timer.
    private var sendGeneration = 0

    private func dismissChat(after delay: TimeInterval, generation: Int? = nil) {
        let generation = generation ?? sendGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // Still an agent session when the timer comes round, or this is
            // none of our business. The user can start dictating inside the
            // wrap-up beat, and `show()` bumps the hide generation but not this
            // one — so without the mode check an agent turn that finished three
            // seconds ago would fade out the user's own recording pill
            // mid-sentence and take the level meter's timer with it.
            guard let self, self.sendGeneration == generation,
                  self.model.mode == .agent else { return }
            withAnimation(.easeIn(duration: 0.28)) { self.model.chatIsOpen = false }
            self.hide()
        }
    }

    // One thread per lease. The same lease coming back — a second question in
    // the same session — reopens the thread it already has; a different one
    // starts empty, because two agents' conversations are not one conversation.
    private func adoptThread(lease: String?) {
        // No lease to go on — a caller that doesn't know which session this is
        // (the demo, an older call site) must not be read as "a different one"
        // and wipe a thread that is still being added to.
        guard let lease, lease != model.chatLease else { return }
        model.chatLease = lease
        model.resetChat()
    }

    // Consent mode 2: the same pill, in a pending state. The callbacks are
    // whatever the controller wants an accept or a decline to mean — Esc and
    // the hotkey are wired up outside, and land on these same two.
    func showConsent(prompt: ConsentPrompt,
                     onAccept: @escaping () -> Void,
                     onDecline: @escaping () -> Void) {
        announceTask?.cancel()
        enterAgentMode(lease: prompt.lease)
        model.agentPhase = .pending
        model.agentCaller = callerLabel(prompt.name)
        model.agentHarness = callerLabel(prompt.harness)
        model.consent = prompt
        model.onAcceptConsent = onAccept
        model.onDeclineConsent = onDecline
        present()
        panel?.ignoresMouseEvents = false
    }

    // The question resolved — by a click, a spoken answer or the deadline.
    // Only the controls go; the pill stays for whatever happens next.
    func dismissConsent(phase: AgentIndicatorPhase = .listening) {
        let hadPrompt = model.consent != nil
        model.consent = nil
        model.onAcceptConsent = nil
        model.onDeclineConsent = nil
        // Only when a question was actually on screen. This runs on every
        // teardown, not just after a prompt — `endAgentSession` calls it before
        // it has even decided whether anything of ours is up — and an
        // unconditional `.listening` overwrote the tick `sendDraft` had set one
        // line earlier. The pill then fell through to the "listening with a
        // closed microphone" spinner and faded out still spinning, so every
        // completed turn ended by looking like one that had hung.
        if hadPrompt { model.agentPhase = phase }
    }

    // Switching into the agent variant. A session already in it keeps
    // everything; arriving from anywhere else starts clean, so no dictation
    // state (a lock, a notice, a Basic tag) and no previous agent's words can
    // ride along.
    private func enterAgentMode(lease: String? = nil) {
        // The carry-over clears run on EVERY session start, not just the
        // transition into agent mode: two agent sessions can follow each other
        // faster than the pill's fade-out, so `mode` is still `.agent` when
        // the second begins and the old guard skipped the whole reset —
        // leaving the previous conversation's transcript on the new pill.
        //
        // The thread is the exception, and the reason adoptThread exists: it
        // belongs to the lease, not to the turn, so the same agent asking again
        // keeps what it already said and only a different one starts clean.
        adoptThread(lease: lease)
        model.agentTranscript = ""
        // A prompt that is still waiting survives unless this is positively a
        // different session. Mode 3 asks by speaking, and speaking is a
        // `showAgentSession` — so clearing the consent here took the accept and
        // decline controls off the pill for the whole time the question was
        // being read out, which is exactly when someone looking at the screen
        // would reach for them.
        //
        // Note the nil case: during that spoken prompt the bridge has not yet
        // published the holder, so the caller genuinely does not know the lease
        // and passes nil. Comparing nil to the prompt's lease read as "a
        // different session" and cleared it anyway, which made the first
        // version of this fix do nothing at all. Unknown means leave it alone;
        // only a lease that is present *and* different is stale.
        if let lease, model.consent?.lease != lease {
            model.consent = nil
            model.onAcceptConsent = nil
            model.onDeclineConsent = nil
        }
        guard model.mode != .agent else { return }
        levelTimer?.invalidate()
        levelTimer = nil
        model.mode = .agent
        model.hint = nil
        model.notice = nil
        model.isLocked = false
        model.isCommand = false
        model.isWarming = false
        model.stillListening = false
        model.level = 0
        model.bands = SpectrumAnalyzer.silent
        applyPanelSize()
    }

    // What the session calls itself — "fixing tests" — which is what the user
    // reads on the pill and hears in the prompt. It used to be the tool's name,
    // shown only when more than one was installed, and that answered a question
    // nobody had: with one harness "an agent" was noise, and with two windows
    // of the same one "Claude Code" could not tell them apart. Falls back to
    // nothing, which the pill reads as "an agent".
    private func callerLabel(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        return name
    }

    // The window the pill floats in differs per variant. position() sets it for
    // a pill that is about to appear; this is the other case — a variant change
    // while it is already on screen, which resizes around the pill's own centre
    // so it doesn't appear to move.
    private func applyPanelSize() {
        guard let panel, panel.isVisible, panel.frame.size != currentPanelSize else { return }
        let centre = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        isRepositioning = true
        defer { isRepositioning = false }
        panel.setContentSize(currentPanelSize)
        panel.setFrameOrigin(NSPoint(x: centre.x - panel.frame.width / 2,
                                     y: centre.y - panel.frame.height / 2))
    }

    private var currentPanelSize: NSSize {
        if model.mode == .agent { return Self.agentPanelSize }
        return model.agentWaiting ? Self.panelSizeWithAgentWaiting : Self.panelSize
    }

    func hide() {
        announceTask?.cancel()
        levelTimer?.invalidate()
        levelTimer = nil
        model.level = 0   // let the meter drain rather than freeze mid-fade
        model.bands = SpectrumAnalyzer.silent
        model.micIsLive = false
        // The panel goes with the pill it hangs off. The thread itself stays —
        // it belongs to the lease, and the same agent asking again reopens the
        // conversation rather than starting a second one.
        model.chatIsOpen = false
        model.chatIsSending = false
        model.chatIsSettling = false
        model.chatDraftIsVisible = false
        guard let panel, isShowing else { return }
        isShowing = false
        // Read before the fade, and only on the transition out of `isShowing`,
        // so a second `hide()` on an already-hidden pill can't sound it twice.
        // Cleared here as well as at session start: a hint pill can go up on
        // its own (a hotkey pressed before setup is finished) and hide itself
        // 2.2 s later, and a lock left standing from the session before would
        // have that unrelated pill sound the end of a session already over.
        if model.isLocked || model.isCommand { onHandsFreeEnd?() }
        model.isLocked = false
        model.isCommand = false
        model.isWarming = false
        panel.ignoresMouseEvents = true
        hideGeneration += 1
        let generation = hideGeneration
        let elapsed = ProcessInfo.processInfo.systemUptime - shownAt
        let delay = max(0, Self.minimumVisible - elapsed)
        guard delay > 0 else { return fadeOut(generation) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.fadeOut(generation)
        }
    }

    private func fadeOut(_ generation: Int) {
        guard hideGeneration == generation, let panel, panel.isVisible else { return }
        isFadingOut = true
        // The drain plays inside the alpha fade's window; ease-in mirrors the
        // entrance the way the badge's exit mirrors its arrival.
        withAnimation(.easeIn(duration: Self.fadeDuration)) { model.revealed = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hideGeneration == generation else { return }
                self.isFadingOut = false
                panel.orderOut(nil)
                self.model.revealed = true   // rest state for the next show
                // Leave agent mode once the pill is actually gone. `hide()`
                // never reset it, so a second agent session's `enterAgentMode`
                // saw `mode == .agent` and short-circuited — keeping the
                // previous conversation's transcript on screen under the new
                // question. Doing it here, off-screen, avoids any mid-fade
                // flicker.
                if self.model.mode == .agent {
                    self.model.mode = .recording
                    self.model.agentTranscript = ""
                }
            }
        })
    }

    private func present() {
        hideGeneration += 1   // cancel any pending or in-flight hide
        let panel = ensurePanel()
        if !isShowing {
            isShowing = true
            shownAt = ProcessInfo.processInfo.systemUptime
        }
        // Already on screen: only the pill's contents changed. Re-running the
        // fade (or re-deriving the position, which follows the mouse's screen)
        // is what made every state change blink and occasionally jump displays.
        guard !panel.isVisible else {
            if isFadingOut || panel.alphaValue < 1 { fadeIn(panel) }
            // A show that caught an exit mid-drain springs the pill back up
            // from wherever the drain had it.
            if !model.revealed { reveal() }
            return
        }
        position(panel)
        panel.alphaValue = 0
        // Start shrunk while still invisible, then bloom on the next turn —
        // same-turn would render the resting state straight away.
        model.revealed = false
        panel.orderFrontRegardless()
        fadeIn(panel)
        DispatchQueue.main.async { [weak self] in self?.reveal() }
    }

    private func reveal() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) { model.revealed = true }
    }

    // Ramps from wherever alpha is now, so catching a fade-out mid-flight
    // reverses it instead of restarting from invisible.
    private func fadeIn(_ panel: NSPanel) {
        isFadingOut = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.panelSize.width,
                                                height: Self.panelSize.height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        model.onResetPosition = { [weak self] in
            guard let self else { return }
            self.settings?.indicatorPosition = nil
            if let panel = self.panel { self.position(panel) }
        }
        panel.contentView = NSHostingView(rootView: IndicatorView(model: model))
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordUserMove() }
        }
        self.panel = panel
        return panel
    }

    // A drag ended somewhere new — remember it as fractions of the screen's
    // visible frame so the spot survives resolution and screen changes.
    // The saved spot is the PILL's, not the window's. The pill sits at the
    // centre of its window in every mode, but the agent window is far taller
    // (it is mostly headroom for the chat panel) — recording the window's own
    // corner meant the same fraction put the pill in two different places
    // depending on which variant was up, and dragging it in one mode moved it
    // in the other. Everything here converts through the pill's centre, using
    // the dictation window as the yardstick so an old saved value still means
    // what it did.
    private func recordUserMove() {
        guard !isRepositioning, let panel, panel.isVisible,
              let screen = panel.screen ?? NSScreen.main else { return }
        let f = screen.visibleFrame
        let base = Self.panelSize
        let denomX = max(f.width - base.width, 1)
        let denomY = max(f.height - base.height, 1)
        settings?.indicatorPosition = CGPoint(
            x: (panel.frame.midX - base.width / 2 - f.minX) / denomX,
            y: (panel.frame.midY - base.height / 2 - f.minY) / denomY)
        // A drag mid-session moves the pill without going through `position()`,
        // which only runs for a pill that is about to appear.
        placeChatPanel(pillCentre: CGPoint(x: panel.frame.midX, y: panel.frame.midY), in: f)
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let screen else { return }
        isRepositioning = true
        defer { isRepositioning = false }
        panel.setContentSize(currentPanelSize)
        let f = screen.visibleFrame
        let base = Self.panelSize
        let centre: CGPoint
        if let saved = settings?.indicatorPosition {
            let fx = min(max(saved.x, 0), 1)
            let fy = min(max(saved.y, 0), 1)
            centre = CGPoint(x: f.minX + fx * (f.width - base.width) + base.width / 2,
                             y: f.minY + fy * (f.height - base.height) + base.height / 2)
        } else {
            centre = CGPoint(x: f.midX, y: f.minY + 96 + base.height / 2)
        }
        panel.setFrameOrigin(NSPoint(x: centre.x - panel.frame.width / 2,
                                     y: centre.y - panel.frame.height / 2))
        placeChatPanel(pillCentre: centre, in: f)
    }

    // Where the conversation can actually go, given where the pill is sitting.
    //
    // Two decisions, both of them about the screen edges rather than the pill:
    // whether there is room above (if not, it hangs below instead — dragging
    // the pill to the top of the screen is supported and remembered, and would
    // otherwise put the whole conversation off the display), and how far it has
    // to slide sideways to stay on screen, since the panel is wider than the
    // pill it is centred on and a pill dragged into a corner would take part of
    // the conversation with it.
    private func placeChatPanel(pillCentre centre: CGPoint, in frame: CGRect) {
        model.chatOpensDownward = centre.y + Self.agentPanelReach > frame.maxY
        let half = AgentChatPanel.width / 2
        let overflowLeft = max(0, (frame.minX + half) - centre.x)
        let overflowRight = max(0, (centre.x + half) - frame.maxX)
        model.chatNudgeX = overflowLeft - overflowRight
    }
}

@MainActor
final class IndicatorModel: ObservableObject {
    enum Mode: Equatable { case recording, transcribing, hint, agent }
    @Published var mode: Mode = .recording
    @Published var level: Float = 0
    // Per-band levels (0…1), low frequency first — what the meter draws.
    @Published var bands: [Float] = SpectrumAnalyzer.silent
    // An agent asked for the microphone while the user was using it. Shown on
    // the dictation pill — every variant of it — because the alternative is
    // that the agent's request is invisible: it is refused somewhere in a
    // terminal the user is not looking at, and the reason they never heard
    // from it is a thing only the agent knows.
    @Published var agentWaiting = false

    @Published var hint: String?
    @Published var isLocked = false
    @Published var stillListening = false
    // The pill is up but the microphone isn't open yet — the engine start is
    // still running. Cleared at the same moment the start cue plays.
    @Published var isWarming = false
    // Bumped each time the still-listening reminder latches. A counter rather
    // than a flag: the pill's wobble is an event, and `stillListening` going
    // true is a state the view may already have been in.
    @Published var nudge = 0
    @Published var isBasic = false
    @Published var isCommand = false
    @Published var notice: String?
    // Overrides the "Typing…" caption (e.g. "Polishing…" while a rewrite runs).
    @Published var transcribingLabel: String?
    // Whether background noise is being filtered right now. Mirrored here
    // rather than read from settings so the pill redraws the moment it changes.
    @Published var noiseReduction = false
    // A filter flip's capture rebuild is in flight; the badge spins.
    @Published var noiseBusy = false
    // Whether the route allows filtering at all; gates the quick menu toggle.
    @Published var noiseReductionAvailable = true
    // Entrance/exit: false renders the pill shrunk and dropped, true at rest.
    // The panel drives it inside withAnimation so an interrupted exit springs
    // back from wherever it was, and leaves it un-animated when the user has
    // turned the effect off.
    @Published var revealed = true
    // The agent variant (§7.1d). Inert in every other mode — the pill only
    // reads these while `mode == .agent`.
    @Published var agentPhase: AgentIndicatorPhase = .listening
    // What the session called itself ("fixing tests"), and the tool it is
    // running in ("claude-code"). The badge prefers the session name and falls
    // back to the harness: a session that gave no name of its own is still a
    // known program, and naming that is far more use than "Agent".
    @Published var agentCaller: String?
    @Published var agentHarness: String?
    // The thread the chat panel is showing, and which lease it belongs to.
    @Published var chatMessages: [AgentChatMessage] = []
    @Published var chatDraft = ""
    @Published var chatDraftIsVisible = false
    // The savings badge that flies off the composer when the rewrite lands.
    // Nil whenever there is nothing to celebrate, which is most of the time.
    @Published var tokenSaving: TokenSaving?

    struct TokenSaving: Equatable, Identifiable {
        let id: Int
        let tokens: Int
        // Which way it drifts as it rises. Randomised per badge so two in a
        // row are not the same gesture twice — the whole charm of the thing it
        // is borrowed from is that the coins never quite repeat.
        let drift: CGFloat
    }

    @Published var chatIsSending = false
    // The turn is over and the words are being transcribed and cleaned up: the
    // microphone is shut, nothing is being added, and the send has not happened
    // yet. It is the one moment of an agent turn where the user is waiting on us.
    @Published var chatIsSettling = false
    @Published var chatIsOpen = false
    // Set by the panel from the pill's position on screen: false opens the
    // conversation above the pill, true below it when there is no room above.
    @Published var chatOpensDownward = false
    // How far the conversation has to slide sideways to stay on screen — the
    // panel is wider than the pill it hangs off, so a pill in a corner would
    // otherwise take part of the thread over the edge with it.
    @Published var chatNudgeX: CGFloat = 0
    var chatLease: String?
    private var chatNextID = 0
    // The bubble that came out of the composer on this turn — the one that
    // inherits the draft field's position for the send animation.
    @Published var lastSentMessageID: Int?

    func appendChatMessage(author: AgentChatMessage.Author, text: String) {
        chatNextID += 1
        chatMessages.append(AgentChatMessage(id: chatNextID, author: author, text: text))
        if author == .user { lastSentMessageID = chatNextID }
    }

    // The turn has been sent and the pill is closing on its checkmark.
    var agentIsDone: Bool { mode == .agent && agentPhase == .done }

    func resetChat() {
        chatMessages = []
        chatDraft = ""
        chatDraftIsVisible = false
        chatIsSending = false
        chatIsSettling = false
        lastSentMessageID = nil
    }

    // What the draft field says before any words have landed: the microphone is
    // open and nothing has been heard yet, which is a different thing from a
    // field waiting to be typed in.
    var chatDraftPlaceholder: String {
        micIsLive ? loc("Listening…") : loc("Waiting…")
    }
    // Everything heard so far this turn; the pill draws the tail of it.
    @Published var agentTranscript = ""
    // A decision the user has not made yet: while this is set the pill wears
    // its accept/deny controls.
    @Published var consent: ConsentPrompt?

    // Whether the microphone is genuinely capturing right now. Set by the
    // controller when capture starts and clears when it stops, rather than
    // inferred from the consent mode: confirm-by-voice keeps the mic shut for
    // the several seconds it takes to speak the question, so a pill that
    // inferred "mode 3 means listening" drew a level meter over a closed
    // microphone — a listening affordance at the one moment nothing is
    // listening, and indistinguishable from a microphone that had failed.
    @Published var micIsLive = false
    // Whether the voice is audibly speaking right now, as opposed to being
    // synthesized. Drawing the helix during synthesis showed a voice that
    // wasn't talking yet — reported as the wave being stuck and then jumping
    // to catch up when the audio finally started.
    @Published var voiceIsPlaying = true
    var onAcceptConsent: (() -> Void)?
    var onDeclineConsent: (() -> Void)?
    var onStop: (() -> Void)?
    var onToggleNoiseReduction: (() -> Void)?
    var onResetPosition: (() -> Void)?
    var settings: SettingsStore?
    // Which clean-up levels the quick menu offers (Concise only where the
    // rewrite engine exists) — supplied by the controller.
    var levelsProvider: (() -> [PolishLevel])?
}

// The chat panel's measured height, so the pill can push it up by exactly that
// much and keep its own position.
private struct ChatHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// The still-listening wobble: two passes left and right, each smaller than the
// last, over half a second. Sideways only and a few points wide — the pill is
// not reporting a fault, it is clearing its throat — and damped to nothing by
// the end so it settles exactly where the user parked it.
//
// `progress` counts wobbles rather than running 0→1, and the effect reads its
// fractional part. Driving it 0→1 and resetting to 0 for the next one looks
// identical on paper and moves exactly once in practice: the reset and the
// animation land in the same update, SwiftUI keeps the last write, and every
// wobble after the first animates 1→1. Counting up, each one is a real change.
private struct StillListeningNudge: GeometryEffect {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        // Whole values are the rest position — sin(0) is 0 — so the pill sits
        // still between wobbles no matter how many it has done.
        let t = progress - progress.rounded(.down)
        let travel = sin(t * .pi * 4) * 6 * (1 - t)
        return ProjectionTransform(CGAffineTransform(translationX: travel, y: 0))
    }
}

struct IndicatorView: View {
    // Pulled out of the row's switch: inline, the nested optional-and-ternary
    // was enough on its own to put the whole body past what the type-checker
    // will attempt in reasonable time.
    private var transcribingText: String {
        if let label = model.transcribingLabel { return label }
        return model.isCommand ? loc("Working…") : loc("Typing…")
    }

    // The mic is grey until the microphone is genuinely open, and takes its
    // session colour at the same instant the start cue plays.
    //
    // The pill goes up on the key down — a hotkey that appears to do nothing
    // reads as broken — but the engine behind it can take the better part of a
    // second (voice processing, a Bluetooth device negotiating its profile).
    // Drawn live from the first frame, the pill was making a promise the
    // microphone hadn't kept: it looked ready, the cue arrived later, and the
    // sound read as lagging the pill rather than as the moment it was for.
    // Grey first, colour with the cue, and the two agree.
    //
    // Also keeps the switch out of the row: the mic's tint inline was one of
    // the ternaries that pushed this body past what the type-checker will
    // attempt in reasonable time.
    private var micTint: Color {
        if model.isWarming { return .secondary }
        if model.isCommand { return .purple }
        return model.isLocked ? .orange : .red
    }

    @ObservedObject var model: IndicatorModel
    // The pointer is over the pill. Everything optional on it appears on this,
    // so the resting state stays a mic and a meter.
    @State private var hovering = false
    // 0 → 1 over one wobble. Driven, not toggled, so the effect below can read
    // a single number and the animation can be replayed from the top.
    @State private var nudgeProgress: CGFloat = 0
    // 0 → 1: how far the border, and separately the tint, have spread out
    // from the badge. Two values because the outline should arrive first and
    // the colour fill in behind it — a line drawn, then the wash. Driven
    // explicitly so turning the feature off plays the same journey backwards
    // before the badge goes grey.
    @State private var borderReveal: CGFloat = 0
    @State private var tintReveal: CGFloat = 0
    // The badge exists only while filtering is on. `lit` is its colour —
    // Aloud blue while the feature is, grey for the moment after it is
    // switched off, so the badge is seen to change before it leaves.
    @State private var badgeVisible = false
    @State private var badgeLit = false
    @State private var badgeFadeOut: Task<Void, Never>?
    // Bumped on every noiseReduction change. A rapid re-toggle starts a new
    // generation before the previous one's fade-out completion fires, so that
    // stale completion can tell it no longer describes the current state and
    // bail instead of forcing the badge back off underneath the new state.
    @State private var noiseGeneration = 0
    // How tall the chat panel currently is, so it can be pushed up by exactly
    // its own height and sit on top of the pill.
    @State private var chatHeight: CGFloat = 0

    // The row itself, lifted out of `body`.
    //
    // Not a matter of taste: with the overlays the pill now carries, the
    // switch inline pushed the whole body past what the type-checker will
    // attempt, and the compiler's answer is to refuse the file rather than
    // to be slow. Each case is unchanged.
    @ViewBuilder
    private var row: some View {
        switch model.mode {
        case .recording:
            // Leaves downward, and is gone before the agent row arrives.
            // The handover is a sequence, not a cross-fade: this drops away,
            // then the agent pill takes its place, then the chat opens out of
            // that, then the voice starts. Two pills dissolving through each
            // other read as one indicator glitching rather than as one
            // finishing and another beginning.
            recordingRow
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: .move(edge: .bottom).combined(with: .opacity)
                        .animation(.easeIn(duration: 0.18))))
        case .transcribing:
            ProgressView()
                .controlSize(.small)
            Text(transcribingText)
                .foregroundStyle(.secondary)
        case .agent:
            // A whole variant rather than a row of its own: it stacks two
            // rows inside the same capsule (AgentIndicator.swift).
            //
            // It arrives *after* whatever it is replacing has gone, rather than
            // fading up through it. Cross-fading two pills means a moment where
            // both are half-present and the agent row appears to be drawn
            // inside the dictation one — read as a glitch rather than as a
            // handover. The delay is only on the way in; leaving stays prompt,
            // so the sequence is "that finished, then this began".
            AgentIndicatorContent(model: model)
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.22)),
                    removal: .opacity.animation(.easeIn(duration: 0.14))))
        case .hint:
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(model.hint ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    // The capsule behind the row, lifted out for the same reason `row` was:
    // inline it was enough, on its own, to put the body past what the
    // type-checker will attempt. Unchanged otherwise.
    @ViewBuilder
    private var pillBackground: some View {
        ZStack {
            Capsule().fill(.ultraThinMaterial)
            if model.mode == .agent {
                // The agent variant wears its accent for the whole session
                // — the one thing on screen that says this microphone was
                // opened by something other than the user. It takes the
                // capsule's colour outright rather than sharing it with the
                // filtering tint, which means the same "Aloud is doing
                // something to your audio" blue and would only muddy it.
                // Light on both: a session can be up for a whole
                // conversation, and the first cut — a heavy fill under a
                // 1.5 pt border — was a lit-up pill sitting over someone's
                // work for minutes at a time. Enough colour to say "not
                // you", not enough to demand anything.
                Capsule().fill(Color.agent.opacity(0.10))
                Capsule().strokeBorder(Color.agent.opacity(0.5), lineWidth: 1)
            } else {
                // Filtering on: the pill takes Aloud's own blue, as a tint
                // through the material and a border around it. Both are
                // revealed by a circle opening out from the badge, so the
                // colour arrives from the thing that was just pressed and
                // meets itself at the far end.
                Capsule().fill(Color.aloud.opacity(0.22))
                    .mask { revealMask(tintReveal) }
                Capsule().strokeBorder(Color.aloud.opacity(0.85), lineWidth: 1.5)
                    .mask { revealMask(borderReveal) }
            }
        }
    }

    // The dictation row, lifted out so it can carry a transition of its own
    // — and so the switch it came from stays inside what the type-checker
    // will attempt.
    @ViewBuilder
    private var recordingRow: some View {
        // Hands-free trades the red mic for an orange one plus a lock —
        // a quiet "still listening" that users can discover on their own.
        // A command hold gets a purple mic: Aloud is listening for an
        // instruction, not taking dictation.
        Image(systemName: "mic.fill")
            .foregroundStyle(micTint)
            .animation(.easeOut(duration: 0.18), value: model.isWarming)
            .symbolEffect(.pulse, isActive: model.stillListening)
        // Reduced-accuracy session: same tag style as onboarding
        // badges, present in held and hands-free pills alike.
        if model.isBasic {
            BasicDictationTag()
        }
        if let notice = model.notice {
            Text(notice)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // The pill is a fixed width; a long note shrinks a
                // little rather than being cut off mid-word.
                .minimumScaleFactor(0.8)
        } else if model.stillListening {
            StillListeningCaption()
                .frame(width: 90)
        } else {
            SpectrumMeter(bands: model.bands, tint: meterTint)
                .frame(width: 90, height: 18)
        }
        if model.isLocked {
            // No padlock: the close button is the thing that says this
            // session is running on its own and has to be ended, and
            // saying it twice in a row that narrow just crowds it.
            Button {
                model.onStop?()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(loc("Stop — or press Esc"))
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            row
        }
        .font(.system(size: 13, weight: .medium))
        // A sent turn draws the capsule in around its checkmark, so the pill
        // ends as a token the size of the tick itself: the message left, and
        // this is the receipt. Everything else about the pill is unchanged, so
        // it is the same object shrinking rather than a new one appearing.
        .padding(.horizontal, model.agentIsDone ? 11 : 16)
        .padding(.vertical, 10)
        .background { pillBackground }
        .overlay(Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        // The menu belongs to the pill, not to the badge sitting on its
        // corner: attached out here it covers the badge too, and every click
        // meant for the badge opens the menu instead. The badge goes on top,
        // after this, so it gets its own clicks in every mode.
        .contextMenu { quickMenu }
        .overlay(alignment: .topTrailing) { noiseBadge.offset(x: 8, y: -8) }
        // The conversation, hung above the pill. An overlay rather than a row
        // in a stack on purpose: overlays take no part in layout, so the pill
        // stays exactly where the user put it and the panel grows upward out of
        // it — measured, then offset by its own height so its bottom edge meets
        // the pill's top.
        // Anchored to whichever edge the conversation grows from, so the
        // offset below is the same magnitude in both directions.
        .overlay(alignment: model.chatOpensDownward ? .bottom : .top) { chatPanel }
        .onPreferenceChange(ChatHeightKey.self) { height in
            Task { @MainActor in chatHeight = height }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: model.chatIsOpen)
        // The session's name, on the opposite corner from the noise badge and
        // in the same idiom: something true of the whole session, sitting proud
        // of the pill rather than taking a place in its row.
        .overlay(alignment: .topLeading) { agentNameBadge.offset(x: -8, y: -8) }
        // Above the pill rather than beside it: the pill's row is already
        // spoken for by the user's own dictation, and this is about something
        // else entirely.
        .overlay(alignment: .top) { agentWaitingBubble.offset(y: -RecordingIndicatorPanel.agentWaitingGap) }
        // The collapse onto the checkmark: one spring for the capsule, the
        // badge, and the row inside it, so they arrive together.
        //
        // Below the overlay, not above it. A modifier only reaches the view it
        // is attached to, and an overlay added afterwards is not that view — so
        // with the animation higher up the capsule collapsed on a spring while
        // the badge, which has a removal transition of its own, had no
        // transaction to run in and simply blinked out.
        .animation(.spring(response: 0.32, dampingFraction: 0.75), value: model.agentIsDone)
        // Below every overlay so the badges travel with the pill: a capsule
        // sliding out from under its own noise badge would read as a glitch,
        // not as one object being nudged.
        .modifier(StillListeningNudge(progress: nudgeProgress))
        .onChange(of: model.nudge) { _, count in
            // Linear, so the two passes are evenly paced — the damping in the
            // effect is what makes it settle, and an eased curve on top of it
            // read as a stumble rather than a wobble.
            withAnimation(.linear(duration: 0.45)) { nudgeProgress = CGFloat(count) }
        }
        .onAppear {
            // Catch up to the model's count without moving. The counter lives
            // on the model and outlives this view; starting at zero against a
            // model at three would animate three whole wobbles in a row the
            // next time the reminder latched.
            nudgeProgress = CGFloat(model.nudge)
            // A pill that opens with filtering already on shows it, rather
            // than animating something the user didn't just do.
            let on: CGFloat = model.noiseReduction ? 1 : 0
            borderReveal = on
            tintReveal = on
            badgeVisible = model.noiseReduction
            badgeLit = model.noiseReduction
        }
        .onChange(of: model.noiseReduction) { _, on in
            badgeFadeOut?.cancel()
            badgeFadeOut = nil
            noiseGeneration += 1
            let generation = noiseGeneration
            if on {
                // The badge appears and the outline runs round together, in
                // the same breath as the press; the colour follows behind and
                // settles a moment later.
                withAnimation(.easeOut(duration: 0.3)) {
                    badgeVisible = true
                    badgeLit = true
                    borderReveal = 1
                }
                withAnimation(.easeOut(duration: 0.6)) { tintReveal = 1 }
            } else {
                withAnimation(.easeIn(duration: 0.3)) { borderReveal = 0 }
                // The badge is the last thing to change, the way it was the
                // first: only once the colour has drained all the way home
                // does it go grey, hold long enough to be seen doing it, and
                // then leave.
                withAnimation(.easeIn(duration: 0.6), completionCriteria: .removed) {
                    tintReveal = 0
                } completion: {
                    // A re-toggle before this fires started a fresh
                    // generation above; a stale completion must not force
                    // the badge back off underneath the state it since moved to.
                    guard generation == noiseGeneration else { return }
                    badgeLit = false
                    badgeFadeOut = Task {
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        guard !Task.isCancelled, generation == noiseGeneration else { return }
                        withAnimation(.easeOut(duration: 0.25)) { badgeVisible = false }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(duration: 0.25), value: model.mode)
        .animation(.spring(duration: 0.25), value: model.isLocked)
        .animation(.spring(duration: 0.25), value: model.stillListening)
        .animation(.spring(duration: 0.25), value: model.notice)
        // The pill grows a touch under the pointer and settles back when it
        // leaves — enough to say "this is a thing you can touch" without
        // becoming a moving target while someone is talking.
        .scaleEffect(hovering && model.mode == .recording ? 1.03 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.noiseReduction)
        // Entrance/exit, in the badge's family: the pill blooms up into place
        // and drains back down. Purely a render of `revealed` — the panel
        // decides when and whether it animates.
        .scaleEffect(model.revealed ? 1 : 0.72)
        .offset(y: model.revealed ? 0 : 12)
        .onHover { hovering = $0 }
    }

    // The conversation, hung above the pill. Its own property because the pill's
    // body is already at the limit of what the type checker will do in one
    // expression.
    @ViewBuilder
    private var chatPanel: some View {
        // Never while a decision is pending. The question on the pill is the
        // only thing being asked at that moment, and a conversation open behind
        // it is a second thing to read before answering the first.
        if model.mode == .agent, model.chatIsOpen, model.consent == nil {
            AgentChatPanel(model: model, opensDownward: model.chatOpensDownward)
                // An overlay is offered its host's size, and the host here is a
                // pill some 40 points tall: without this the thread's scroll
                // view took that as its height, collapsed to nothing, and the
                // panel showed a draft field with no conversation above it.
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(key: ChatHeightKey.self, value: geo.size.height)
                    }
                }
                .offset(x: model.chatNudgeX,
                        y: (model.chatOpensDownward ? 1 : -1)
                        * (chatHeight + AgentChatPanel.gap))
                // The panel is pushed up by its own measured height, so the
                // height and the offset have to move together or it slides
                // through the pill on its way to the new size.
                .animation(.spring(response: 0.32, dampingFraction: 0.85), value: chatHeight)
                // In and out along the same path: it grows out of the pill's
                // top edge and, when the exchange is over, settles back down
                // into it. An opacity-only exit made the panel evaporate where
                // it stood, which reads as a thing being cancelled rather than
                // a conversation finishing.
                .transition(.scale(scale: 0.86, anchor: .bottom).combined(with: .opacity))
        }
    }

    // A circle centred on the badge, opening out until it covers the whole
    // pill. Masking the tint and the border with it makes the colour appear to
    // run around the capsule in both directions at once and close on the
    // opposite side — one value to animate, and it reverses for free.
    private func revealMask(_ progress: CGFloat) -> some View {
        GeometryReader { geo in
            let reach = 2 * sqrt(geo.size.width * geo.size.width
                                 + geo.size.height * geo.size.height)
            Circle()
                .frame(width: reach * progress, height: reach * progress)
                .position(x: geo.size.width - 4, y: 4)   // the badge's centre
        }
    }

    // Background-noise filtering, as a badge on the pill.
    //
    // A badge rather than another item in the row, because the row already
    // reads left to right as mode → am I being heard → end this session, and
    // this is none of those: it is a standing fact about how the microphone is
    // being listened to. Sitting proud of the top-right corner, the way a
    // count sits on an app icon, it says so without taking a place in that
    // sentence or crowding the meter.
    //
    // Filled and tinted when filtering is on, and always visible then — the
    // point of it is that you can see the state at a glance. Off, it waits for
    // the pointer and then fades in hollow: same corner, same shape, obviously
    // the same control, obviously not doing anything. Either way one click
    // flips it.
    @ViewBuilder
    private var noiseBadge: some View {
        if model.mode == .recording, badgeVisible {
            Button {
                guard !model.noiseBusy else { return }
                model.onToggleNoiseReduction?()
            } label: {
                Group {
                    if model.noiseBusy {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(badgeLit ? .white : nil)
                    } else {
                        Image(systemName: "waveform.badge.minus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(badgeLit ? AnyShapeStyle(.white)
                                                      : AnyShapeStyle(.secondary))
                    }
                }
                    .frame(width: 24, height: 24)
                    .background {
                        // Off, the pill's own ultra-thin material would make
                        // the badge disappear into it — a heavier backdrop is
                        // what makes it read as a separate, pressable thing.
                        Circle().fill(badgeLit ? AnyShapeStyle(Color.aloud)
                                               : AnyShapeStyle(.regularMaterial))
                    }
                    // A hairline in the window's own backdrop, so the badge
                    // reads as sitting on top of the pill rather than punched
                    // out of it.
                    .overlay(Circle().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .help(loc("Background noise is being filtered — click to stop"))
            // Scale only, no opacity: the badge's own background is a
            // translucent material off, solid on — fading its alpha in on top
            // of the tint/border reveal sweeping in behind it let that sweep
            // show through the badge itself, like a seam cutting across it.
            // Fully opaque throughout, it just grows in instead.
            .transition(.scale(scale: 0.4))
        }
    }

    // The name of the agent session, as a badge on the pill's top-left corner.
    // Same shape language as the noise badge opposite it — a hairline, a solid
    // fill, sitting on top of the capsule rather than punched out of it — so
    // the two read as the same class of thing. Filled in the agent accent
    // because it is also the answer to "who opened this microphone".
    //
    // A session with no name of its own says "Agent", which is all the pill can
    // honestly claim: the name is whatever the harness called the session
    // ("fixing tests"), and an unnamed one is still an agent.
    // "An agent is waiting for you to finish."
    //
    // The situation it exists for: somebody is dictating, an agent asks for the
    // microphone, and it is quite correctly refused — the user is mid-sentence
    // and taking the hotkey would swallow it. Without this, that exchange
    // happens entirely out of sight: the agent is told to try later in a window
    // the user is not looking at, the user finishes and never learns anything
    // wanted them, and the feature simply appears not to work.
    //
    // Two lines because it has two things to say, and the second is the useful
    // one: what is happening, and what to do about it. Shown on every dictation
    // variant — push-to-talk, hands-free, command — since an agent can arrive
    // during any of them.
    @ViewBuilder
    private var agentWaitingBubble: some View {
        if model.agentWaiting, model.mode == .recording {
            AgentWaitingBubble()
                // Rises out of the pill, the way the chat panel does, so it
                // reads as belonging to it rather than floating over it.
                .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var agentNameBadge: some View {
        // Gone the moment the turn is sent: the closing pill is a tick and
        // nothing else, and a name badge riding on a shrinking capsule is the
        // one thing that would make it read as still going.
        if model.mode == .agent, !model.agentIsDone {
            // A glyph, then the name. The name alone is whatever the harness
            // called the session — "fixing tests", "release notes" — and read
            // cold on a pill it is not obviously an agent at all; it looks like
            // a label somebody typed. Saying so in words is what does not fit:
            // the badge caps at 22 characters to stay narrower than the pill,
            // and "Claude Code · fixing tests" is 26 before the task name has
            // even had its say. The glyph costs no characters and answers the
            // question the words were there to answer.
            // A terminal, not sparkles. What is holding the microphone is a
            // command-line coding tool, and that is a concrete thing with a
            // conventional glyph — where sparkles is the decoration every
            // product now puts on anything with a model behind it, and says
            // nothing about who this session is or what it wants.
            HStack(spacing: 3.5) {
                // Outline, not `.fill`. Filled, a terminal at this size is a
                // solid white block — the prompt inside it is finer than one
                // point and disappears, so the glyph that was supposed to say
                // "a command-line tool" said "a square". The outline keeps the
                // window edge and the prompt legible, which is the entire
                // content of the symbol.
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .bold))
                Text(Self.badgeName(model.agentCaller ?? model.agentHarness))
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
                .foregroundStyle(.white)
                // Hugs its text. A maxWidth here doesn't cap a wide badge, it
                // *makes* one: the frame takes whatever the pill underneath
                // proposes, so "Agent" sat in a badge sized for a sentence.
                // A long name is cut in badgeName instead.
                .fixedSize()
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Capsule().fill(Color.agent))
                .overlay(Capsule().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
                .help(loc("The agent session using your microphone"))
                // Tucks into the pill rather than shrinking into its own
                // middle, and fades as it goes. Scaling about the badge's
                // centre left it hanging above the capsule getting smaller,
                // which is the shape of something failing rather than
                // something finishing.
                // Arrives on the same beat as the row it belongs to. The row's
                // insertion waits for the outgoing dictation content to clear,
                // and without the same delay here the badge appeared *before*
                // the pill it is supposed to be pinned to — a name label
                // hanging in space over an indicator that had not arrived yet.
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.4, anchor: .bottomTrailing)
                        .combined(with: .opacity)
                        .animation(.spring(response: 0.3, dampingFraction: 0.8).delay(0.22)),
                    removal: .scale(scale: 0.4, anchor: .bottomTrailing)
                        .combined(with: .opacity)))
        }
    }

    // The badge hugs its text, so the cap is on the text itself: a session that
    // named itself at length is cut rather than allowed to grow a badge wider
    // than the pill it sits on.
    //
    // The caller passes session name ?? harness name; "Agent" is the last
    // resort for a request that carried neither, and in practice never shows —
    // the bridge requires a harness on every claim.
    static func badgeName(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return loc("Agent") }
        guard name.count > 22 else { return name }
        return name.prefix(21).trimmingCharacters(in: .whitespaces) + "…"
    }

    // The meter agrees with the mic glyph in the two modes that have a colour
    // of their own; plain dictation keeps the accent colour, which is quieter
    // next to a red mic than a second red thing would be.
    private var meterTint: Color {
        model.isCommand ? .purple : model.isLocked ? .orange : .accentColor
    }

    // Right-click quick menu: the settings people flip mid-dictation, without
    // a trip to the Settings window. Drag the pill itself to move it.
    @ViewBuilder
    private var quickMenu: some View {
        if let settings = model.settings {
            Picker(loc("Microphone"), selection: Binding(
                get: { settings.microphoneUID },
                set: { settings.microphoneUID = $0 })) {
                Text(loc("System default")).tag(nil as String?)
                ForEach(AudioDevices.inputDevices()) { d in
                    Text(d.name).tag(d.uid as String?)
                }
            }
            Picker(loc("Clean-up"), selection: Binding(
                get: { settings.polishLevel },
                set: { settings.polishLevel = $0 })) {
                ForEach(model.levelsProvider?() ?? PolishLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            // The same switch the badge is, in words. During a held dictation
            // the badge is a small target to hit one-handed, and this menu is
            // already where the other capture settings live.
            Toggle(loc("Reduce background noise"), isOn: Binding(
                get: { model.noiseReduction },
                set: { _ in model.onToggleNoiseReduction?() }))
                .disabled(!model.noiseReductionAvailable)
            Divider()
            Button(loc("Reset Position")) { model.onResetPosition?() }
        }
    }
}

// The hands-free silence reminder, sized to hold the meter's slot on one
// line, with a soft shine sweeping through the glyphs every few seconds —
// for the user glancing back at a screen they stopped watching, a caption
// that moves is found faster than one that sits still.
private struct StillListeningCaption: View {
    // 0 → 1 is one sweep; the gradient band spans well past the text on both
    // sides, so most of each cycle it is off the glyphs entirely — the pause
    // between shimmers comes free, no timer needed.
    @State private var phase: CGFloat = 0

    var body: some View {
        Text(loc("Still listening…"))
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(.orange)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.85), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.55)
                        .offset(x: phase * geo.size.width * 2.6 - geo.size.width * 0.8)
                }
                .mask(
                    Text(loc("Still listening…"))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                )
                .allowsHitTesting(false)
            }
            .onAppear {
                phase = 0
                withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

// One bar per frequency band, low on the left, each rising with the energy the
// mic is picking up there. Silence rests as a row of dots rather than an empty
// gap, so the meter always says "the mic is on" even when nobody is talking.
// System colours, rounded rectangles, no markings — nothing to read, only
// something to recognise.
// Aloud talking, drawn as two strands winding around each other — a helix seen
// side on. It exists to answer one question the meter cannot: the meter means
// "we are listening to you", and during a spoken prompt the microphone is
// deliberately shut, so a meter there is a listening affordance shown at the
// exact moment nothing is listening. Someone watching it saw a flat meter and
// reasonably concluded the microphone was broken.
//
// Two properties carry the meaning. It always *moves* while Aloud speaks, so
// "not listening, talking" reads at a glance even from the corner of the eye.
// And it *reacts*, so the movement is this sentence rather than a spinner: the
// strands swell on words and pinch to a line in the gaps. Where the engine
// cannot tell us the level — the system voice never hands over its samples —
// the motion continues at a resting amplitude, which is the honest picture of
// "speaking, loudness unknown".
struct VoiceWave: View {
    var level: Float
    var tint: Color

    // Turns across the width. Few enough to read as a helix rather than a
    // texture at this size.
    private let turns: Double = 2.2
    private let strandWidth: CGFloat = 2
    // Never fully closed: a helix pinched to a line reads as "stopped", and it
    // is speaking even between two words.
    private let restAmplitude: CGFloat = 0.18
    private let rungs = 11

    var body: some View {
        // .animation drives this from the display link, so the phase advances
        // on its own and the drawing is never waiting on an audio frame.
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let mid = size.height / 2
                let swell = restAmplitude + (1 - restAmplitude) * CGFloat(min(max(level, 0), 1))
                let amplitude = mid * swell

                func strand(_ offset: Double) -> Path {
                    var path = Path()
                    let steps = 48
                    for step in 0...steps {
                        let fraction = Double(step) / Double(steps)
                        let angle = fraction * turns * 2 * .pi + t * 3.2 + offset
                        // Waist the ends so the strands meet rather than being
                        // sliced off by the frame — that join is what makes it
                        // read as one twisting ribbon.
                        let taper = sin(fraction * .pi)
                        let point = CGPoint(x: fraction * size.width,
                                            y: mid + sin(angle) * amplitude * taper)
                        step == 0 ? path.move(to: point) : path.addLine(to: point)
                    }
                    return path
                }

                let front = strand(0)
                let back = strand(.pi)
                // The rungs are what separate a helix from two sine waves. They
                // fade as the strands cross, which is the visual shorthand for
                // the far side of the twist.
                for rung in 0..<rungs {
                    let fraction = (Double(rung) + 0.5) / Double(rungs)
                    let angle = fraction * turns * 2 * .pi + t * 3.2
                    let taper = sin(fraction * .pi)
                    let y = sin(angle) * amplitude * taper
                    var bar = Path()
                    bar.move(to: CGPoint(x: fraction * size.width, y: mid + y))
                    bar.addLine(to: CGPoint(x: fraction * size.width, y: mid - y))
                    ctx.stroke(bar, with: .color(tint.opacity(0.10 + 0.30 * abs(sin(angle)))),
                               lineWidth: 1)
                }
                ctx.stroke(back, with: .color(tint.opacity(0.45)),
                           style: StrokeStyle(lineWidth: strandWidth, lineCap: .round))
                ctx.stroke(front, with: .color(tint.opacity(0.95)),
                           style: StrokeStyle(lineWidth: strandWidth, lineCap: .round))
            }
        }
    }
}

struct SpectrumMeter: View {
    var bands: [Float]
    var tint: Color

    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 3
    private let restHeight: CGFloat = 3
    private let maxHeight: CGFloat = 18

    var body: some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(Array(bands.enumerated()), id: \.offset) { i, value in
                let v = CGFloat(min(max(value, 0), 1))
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(tint.opacity(0.4 + 0.6 * Double(v)))
                    .frame(width: barWidth, height: restHeight + (maxHeight - restHeight) * v)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .bottom)
        // Interpolates between audio frames, which land slower than the display.
        .animation(.linear(duration: 0.05), value: bands)
    }
}

// "An agent wants to speak", over a live dictation.
//
// Quiet on purpose. Filled with the agent accent it was the loudest thing on
// screen while somebody was mid-sentence — shouting over the very activity it
// is asking to interrupt. The pill's own material with an accent-tinted first
// line says the same thing at the volume the situation deserves.
//
// It does signal, though. Sitting perfectly still it reads as a label that has
// always been there, and the one thing it has to convey is that something is
// waiting on the user *now* — so a ring travels out of it, once a beat, into
// the empty space above the pill.
private struct AgentWaitingBubble: View {
    @State private var pinging = false

    var body: some View {
        VStack(spacing: 1) {
            Text(loc("An agent wants to speak"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.agentBright)
            Text(loc("Finish to let it through"))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.agent.opacity(0.4), lineWidth: 0.5))
        // A ring that grows out of the bubble and fades, over and over.
        //
        // Scaling the bubble itself was the first attempt and it was wrong
        // twice over: it grew into the pill below — the one thing on screen it
        // must not cover, since the user is actively using it — and a shape
        // that swells and shrinks reads as breathing rather than as alerting.
        // A ring leaves the bubble still, travels outward into empty space,
        // and is unmistakably a signal. The visual half of an alarm, with the
        // half that makes noise deliberately left out.
        .overlay {
            Capsule()
                .strokeBorder(Color.agent, lineWidth: 1.5)
                .scaleEffect(pinging ? 1.2 : 1)
                .opacity(pinging ? 0 : 0.85)
                .animation(.easeOut(duration: 1.3).repeatForever(autoreverses: false),
                           value: pinging)
                .allowsHitTesting(false)
        }
        .onAppear { pinging = true }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
