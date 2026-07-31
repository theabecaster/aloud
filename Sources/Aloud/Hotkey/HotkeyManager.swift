import AppKit
import Carbon.HIToolbox

// Global push-to-talk via a CGEventTap.
//
// Listen-only tap on keyDown/keyUp/flagsChanged. A lone-modifier hotkey (the
// default, left ⌥) is tracked through flagsChanged transitions; a regular key
// through keyDown/keyUp with matching modifier flags. Esc while holding cancels;
// Esc or another double-tap during a hands-free session finishes it.
//
// The decision logic lives in `HotkeyEngine` (pure, event-in/action-out) so the
// selftest can drive it with synthetic events without installing a real tap —
// installing one requires Accessibility, which CI doesn't have.

enum HotkeyAction: Equatable {
    case begin          // key went down → start recording
    case commit         // key released → stop + transcribe
    case cancel         // Esc while held, or accidental tap → discard
    case lock           // double-press → keep recording hands-free until Esc
    case beginCommand   // command key went down → start a command recording
    case commitCommand  // command key released → transcribe + run the command
    case cancelCommand  // Esc or accidental tap during a command hold → discard
    // An agent is asking to listen and the user answered with the keyboard.
    // The pill offers both in its tooltips — "Accept — or press the Aloud
    // hotkey", "Decline — or press Esc" — and neither did anything: the
    // hotkey started an ordinary dictation on top of the pending question,
    // which is two claimants on one microphone and text typed into whatever
    // app happened to be focused. A prompt owns the keyboard while it is up.
    case consentAccept
    case consentDecline
    case none
}

// Tracks the physical down/up of one hotkey — lone modifier, modifier chord,
// key + modifiers, or mouse button + modifiers — from raw tap events. Pure;
// the engines above it decide what a press means.
struct KeyPressTracker {
    let hotkey: Hotkey
    private(set) var isDown = false
    private var lastChordFlags: CGEventFlags = []

    enum Event: Equatable {
        case down           // the hotkey's keys are now all held
        case up             // a member was released
        case interrupted    // another key/button/modifier arrived while held
        case none
    }

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
    }

    mutating func reset() {
        isDown = false
        lastChordFlags = []
    }

    mutating func handle(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> Event {
        switch type {
        case .flagsChanged:
            let current = flags.intersection(Hotkey.chordable)
            defer { lastChordFlags = current }
            if hotkey.isChord {
                let mask = hotkey.chordMask
                if !isDown {
                    // Down only when the exact chord is reached by *pressing*
                    // (from a proper subset) — releasing ⌘ out of ⌃⌥⌘ must
                    // not fire a ⌃⌥ hotkey.
                    guard current == mask, lastChordFlags != mask,
                          lastChordFlags.isSubset(of: mask) else { return .none }
                    isDown = true
                    return .down
                }
                if !mask.isSubset(of: current) {    // a member came up
                    isDown = false
                    return .up
                }
                if current != mask { return .interrupted }  // extra modifier joined
                return .none
            }
            guard hotkey.isModifierKey, keyCode == hotkey.keyCode,
                  let flag = hotkey.modifierFlag else { return .none }
            let nowDown = flags.contains(flag)
            if nowDown && !isDown { isDown = true; return .down }
            if !nowDown && isDown { isDown = false; return .up }
            return .none

        case .otherMouseDown:
            if hotkey.isMouseButton, keyCode == hotkey.keyCode, !isDown, flagsMatch(flags) {
                isDown = true
                return .down
            }
            return isDown ? .interrupted : .none

        case .otherMouseUp:
            guard hotkey.isMouseButton, keyCode == hotkey.keyCode, isDown else { return .none }
            isDown = false
            return .up

        case .keyDown:
            if !hotkey.isModifierKey, !hotkey.isMouseButton, keyCode == hotkey.keyCode,
               !isDown, flagsMatch(flags) {
                isDown = true
                return .down
            }
            return isDown ? .interrupted : .none

        case .keyUp:
            guard !hotkey.isModifierKey, !hotkey.isMouseButton, keyCode == hotkey.keyCode, isDown
            else { return .none }
            isDown = false
            return .up

        default:
            return .none
        }
    }

    private func flagsMatch(_ flags: CGEventFlags) -> Bool {
        flags.intersection(Hotkey.chordable)
            == CGEventFlags(rawValue: hotkey.modifiers).intersection(Hotkey.chordable)
    }
}

// Pure state machine: feed it event type + keycode + flags, get an action.
//
// Modes:
//   hold: press → .begin … release ≥ minimumHold → .commit (shorter → .cancel)
//   hands-free (optional): two quick taps → second release yields .lock
//     (recording, begun on the second press, continues); another double-tap
//     or Esc finishes → .commit. Single presses while locked are ignored.
//   Esc while *holding* cancels.
//   A foreign key right after the press means the user was typing a shortcut
//   that shares our keys (⌥→ word-jump, ⌃⌥← window snap) — cancel quietly.
//   Past the grace window they're clearly dictating; stray keys are ignored
//   so a long dictation can't be lost to a brushed key.
struct HotkeyEngine {
    var hotkey: Hotkey {
        didSet { tracker = KeyPressTracker(hotkey: hotkey) }
    }
    // When false, double-pressing never locks — the key only works while held.
    var handsFreeEnabled: Bool
    private(set) var isLocked = false
    private var tracker: KeyPressTracker
    private var pressTime: TimeInterval = 0
    private var lastTapTime: TimeInterval = -1
    // The engine's session state, distinct from tracker.isDown: Esc or a
    // foreign-key cancel ends the session while the keys are still physically
    // held, and the leftover release must not commit anything.
    private var heldSession = false

    var isHeld: Bool { heldSession }

    // Holds shorter than this are accidental taps — recording still starts
    // instantly on press; the *commit* is suppressed for sub-threshold holds.
    static let minimumHold: TimeInterval = 0.15
    // Two taps within this window arm hands-free mode.
    static let doubleTapWindow: TimeInterval = 0.4
    // A foreign key inside this window after press = shortcut, not speech.
    static let graceWindow: TimeInterval = 0.5

    init(hotkey: Hotkey, handsFreeEnabled: Bool = true) {
        self.hotkey = hotkey
        self.handsFreeEnabled = handsFreeEnabled
        tracker = KeyPressTracker(hotkey: hotkey)
    }

    // Back to idle, forgetting any held/locked state and pending double-tap.
    mutating func reset() {
        heldSession = false
        isLocked = false
        lastTapTime = -1
        tracker.reset()
    }

    // Jump straight to a hands-free session (the dedicated hands-free key
    // skips the double-tap dance). Caller emits .begin/.lock itself.
    mutating func forceLock() {
        heldSession = false
        isLocked = true
        lastTapTime = -1
    }

    mutating func handle(type: CGEventType, keyCode: UInt16, flags: CGEventFlags,
                         time: TimeInterval) -> HotkeyAction {
        if type == .keyDown, keyCode == UInt16(kVK_Escape), heldSession || isLocked {
            // Esc finishes a hands-free session (all that dictation should
            // type, not vanish) but discards a held one. The tracker resets
            // with it so a re-press can begin fresh even if the keys were
            // never fully released; the leftover release is then a no-op.
            let wasLocked = isLocked
            heldSession = false; isLocked = false; lastTapTime = -1
            tracker.reset()
            return wasLocked ? .commit : .cancel
        }
        switch tracker.handle(type: type, keyCode: keyCode, flags: flags) {
        case .down:
            return press(time: time)
        case .up:
            guard heldSession else { return .none }  // session already ended by Esc/foreign key
            return release(time: time)
        case .interrupted:
            // Another key while we're held: within the grace window it was a
            // shortcut sharing our modifiers — bow out. Later it's a brush.
            guard heldSession, !isLocked, (time - pressTime) < Self.graceWindow else { return .none }
            heldSession = false
            lastTapTime = -1
            return .cancel
        case .none:
            return .none
        }
    }

    private mutating func press(time: TimeInterval) -> HotkeyAction {
        if isLocked {
            // Double-tapping the hotkey again ends hands-free, mirroring how it
            // began. heldSession stays false so this press's release is swallowed
            // and lastTapTime is cleared so the pair can't re-arm a new session.
            if lastTapTime >= 0, (time - lastTapTime) <= Self.doubleTapWindow {
                isLocked = false
                heldSession = false
                lastTapTime = -1
                return .commit
            }
            heldSession = true
            pressTime = time
            lastTapTime = time
            return .none
        }
        heldSession = true
        pressTime = time
        return .begin
    }

    private mutating func release(time: TimeInterval) -> HotkeyAction {
        heldSession = false
        if isLocked {                       // hands-free runs until Esc
            return .none
        }
        if (time - pressTime) >= Self.minimumHold {
            lastTapTime = -1
            return .commit
        }
        // Short tap: second one inside the window locks hands-free (recording
        // already started on this press); a lone one is an accidental cancel.
        if handsFreeEnabled, lastTapTime >= 0, (time - lastTapTime) <= Self.doubleTapWindow {
            isLocked = true
            lastTapTime = -1
            return .lock
        }
        lastTapTime = time
        return .cancel
    }
}

// Pure wrapper for the optional command key: identical hold semantics to a
// dictation hold (press begins, release ≥ minimumHold commits, Esc or a short
// tap cancels) but never hands-free — a command is one held utterance. Reuses
// HotkeyEngine and only relabels its actions so the selftest and unit tests
// can drive it with synthetic events like the main engine.
struct CommandKeyEngine {
    private var engine: HotkeyEngine

    init(hotkey: Hotkey) {
        engine = HotkeyEngine(hotkey: hotkey, handsFreeEnabled: false)
    }

    var hotkey: Hotkey { engine.hotkey }
    var isHeld: Bool { engine.isHeld }

    mutating func reset() { engine.reset() }

    // .none means "not consumed" — the caller falls through to the main engine.
    mutating func handle(type: CGEventType, keyCode: UInt16, flags: CGEventFlags,
                         time: TimeInterval) -> HotkeyAction {
        switch engine.handle(type: type, keyCode: keyCode, flags: flags, time: time) {
        case .begin: return .beginCommand
        case .commit: return .commitCommand
        case .cancel: return .cancelCommand
        default: return .none
        }
    }
}

// What a keystroke means while an agent's consent prompt is on screen.
//
// A prompt owns the keyboard for as long as it is up. Without that, pressing
// the Aloud hotkey to answer "yes" — which the pill's own tooltip tells you to
// do — instead started an ordinary dictation on top of the pending question:
// two claimants on one microphone, text typed into whatever app was focused,
// and an agent waiting on an answer the keyboard had no way to give.
//
// Pure and separate from the tap so the rule is testable. It is a small table
// and every row is a decision:
//
//   begin / lock / beginCommand → yes. Any way of starting to talk to Aloud,
//     while Aloud is asking a yes/no question, is the answer to that question.
//   cancel / cancelCommand      → no. Esc reads as "stop", and stopping a
//     question is declining it.
//   commit / commitCommand      → nothing, and swallowed. This is the release
//     half of the press that just answered; committing a recording that never
//     started is worse than doing nothing.
enum ConsentKeys {
    static func translate(_ action: HotkeyAction,
                          consentIsPending: Bool) -> (emit: HotkeyAction?, consumed: Bool) {
        guard consentIsPending else {
            return (action == .none ? nil : action, false)
        }
        switch action {
        case .begin, .lock, .beginCommand:
            return (.consentAccept, true)
        case .cancel, .cancelCommand:
            return (.consentDecline, true)
        case .commit, .commitCommand:
            return (nil, true)
        case .consentAccept, .consentDecline:
            return (action, true)
        case .none:
            return (nil, false)
        }
    }
}

final class HotkeyManager {
    var onAction: ((HotkeyAction) -> Void)?

    private var engine: HotkeyEngine
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Set while an agent's consent prompt is on screen. Written from the main
    // actor, read on the event tap thread, so it carries a lock rather than
    // relying on the two happening to agree.
    private let consentLock = NSLock()
    private var consentPending = false

    var consentIsPending: Bool {
        get { consentLock.lock(); defer { consentLock.unlock() }; return consentPending }
        set { consentLock.lock(); consentPending = newValue; consentLock.unlock() }
    }

    // Every action leaves through here so the consent translation cannot be
    // applied in one branch and forgotten in another — the hands-free key, the
    // command key and the dictation key each have their own path out.
    //
    // Returns whether the event was consumed answering the prompt, which the
    // caller uses to swallow it: a keystroke that just said "yes" to an agent
    // must not also reach the app underneath.
    @discardableResult
    private func emit(_ action: HotkeyAction) -> Bool {
        let outcome = ConsentKeys.translate(action, consentIsPending: consentIsPending)
        if let emitted = outcome.emit {
            DispatchQueue.main.async { [weak self] in self?.onAction?(emitted) }
        }
        return outcome.consumed
    }

    init(hotkey: Hotkey, handsFree: Bool = true) {
        engine = HotkeyEngine(hotkey: hotkey, handsFreeEnabled: handsFree)
    }

    var hotkey: Hotkey {
        get { engine.hotkey }
        set {
            // Same key → keep the engine, and with it any held/locked session.
            // Rebuilding here mid-dictation would orphan the recording: the
            // fresh engine forgets isLocked, so Esc stops stopping it.
            guard newValue != engine.hotkey else { return }
            engine = HotkeyEngine(hotkey: newValue, handsFreeEnabled: engine.handsFreeEnabled)
        }
    }

    var handsFree: Bool {
        get { engine.handsFreeEnabled }
        set { engine.handsFreeEnabled = newValue }
    }

    // Optional dedicated hands-free key: one clean tap starts a locked
    // session, another finishes it. Handled ahead of the engine; ignored when
    // it duplicates the main key. "Clean" = nothing else pressed between down
    // and up — ⌃⇧-click or ⌃⌘Space is a shortcut, not a hands-free request.
    var handsFreeHotkey: Hotkey? {
        didSet {
            guard handsFreeHotkey != oldValue else { return }
            handsFreeTracker = handsFreeHotkey.map(KeyPressTracker.init)
            handsFreeTapDirty = false
        }
    }
    private var handsFreeTracker: KeyPressTracker?
    private var handsFreeTapDirty = false

    // Optional dedicated command key: hold to speak an instruction, release to
    // run it. A parallel engine (also handled ahead of the main one) so a
    // command hold can never tangle with dictation state; ignored when it
    // duplicates the main key.
    var commandHotkey: Hotkey? {
        didSet {
            guard commandHotkey != oldValue else { return }
            commandEngine = commandHotkey.map(CommandKeyEngine.init)
        }
    }
    private var commandEngine: CommandKeyEngine?

    // Whether the event tap is installed and listening.
    var isActive: Bool { tap != nil }

    // End a hands-free session from the UI — equivalent to pressing Esc.
    func endHandsFree() {
        guard engine.isLocked else { return }
        engine.reset()
        onAction?(.commit)
    }

    // Abandon any in-flight hold or hands-free session without committing.
    func abortSession() {
        guard engine.isHeld || engine.isLocked else { return }
        engine.reset()
        onAction?(.cancel)
    }

    // Returns false when the tap can't be created (Accessibility not granted).
    @discardableResult
    func start() -> Bool {
        stop()
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        // An active (not listen-only) tap so the Esc that ends a held or
        // hands-free session can be swallowed rather than also reaching
        // whatever app has focus — hands-free can sit for minutes, long
        // enough that the Esc meant to stop it often lands in a terminal or
        // editor that treats Esc as its own command. Everything else keeps
        // passing through exactly as it did as a listen-only tap.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                let swallow = manager.handleTapEvent(type: type, event: event)
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else { return false }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    // Returns whether this event is ours alone — swallowed rather than also
    // delivered to whatever app has focus. Only ever true for the Esc that
    // just ended a held or hands-free/command session: every other event
    // (the hotkey itself included) passes through exactly as it did back
    // when the tap was listen-only.
    @discardableResult
    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Bool {
        // macOS disables taps that stall or on timeout — re-enable transparently.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        // The event's own timestamp, not processing time: the tap source runs
        // on the main run loop, so a busy main thread delays when we *see* an
        // event. Measuring hold lengths with the wall clock inflated quick
        // taps into holds and broke the hands-free double-tap.
        let time = Double(event.timestamp) / 1_000_000_000

        // Mouse events carry a button number instead of a keycode.
        let isMouse = type == .otherMouseDown || type == .otherMouseUp
        let keyCode = isMouse
            ? UInt16(clamping: event.getIntegerValueField(.mouseEventButtonNumber))
            : UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let escapeDown = type == .keyDown && keyCode == UInt16(kVK_Escape)

        // Esc only reaches the engines while a dictation session is held, so a
        // pending prompt has to claim it here or the key means nothing.
        if escapeDown, consentIsPending {
            emit(.consentDecline)
            return true
        }

        if let action = handsFreeKeyAction(type: type, keyCode: keyCode, flags: event.flags) {
            if emit(action) { return true }
            return false
        }

        // Command key next: its engine only ever consumes its own key (and Esc
        // during a command hold); anything else returns .none and falls through.
        if commandEngine != nil, commandHotkey != engine.hotkey {
            let commandAction = commandEngine?.handle(
                type: type, keyCode: keyCode, flags: event.flags,
                time: time) ?? .none
            if commandAction != .none {
                if emit(commandAction) { return true }
                return escapeDown
            }
        }

        let action = engine.handle(type: type, keyCode: keyCode, flags: event.flags,
                                   time: time)
        if emit(action) { return true }
        return escapeDown && action != .none
    }

    // Detect a clean tap of the dedicated hands-free key. Returns nil when
    // the event isn't ours (fall through to the engines); .none swallows an
    // event that is ours but toggles nothing. The toggle fires on *release*:
    // if anything else was pressed while the key was down, the user was
    // typing a shortcut that shares these keys, and nothing happens.
    private func handsFreeKeyAction(type: CGEventType, keyCode: UInt16,
                                    flags: CGEventFlags) -> HotkeyAction? {
        guard handsFreeTracker != nil, let hk = handsFreeHotkey, hk != engine.hotkey else { return nil }
        switch handsFreeTracker!.handle(type: type, keyCode: keyCode, flags: flags) {
        case .down:
            handsFreeTapDirty = false
            return HotkeyAction.none
        case .up:
            guard !handsFreeTapDirty else {
                handsFreeTapDirty = false
                return HotkeyAction.none
            }
            // A session in any state ends; idle begins a locked one.
            if engine.isLocked || engine.isHeld {
                engine.reset()
                return .commit
            }
            engine.forceLock()
            DispatchQueue.main.async { [weak self] in self?.onAction?(.begin) }
            return .lock
        case .interrupted:
            handsFreeTapDirty = true
            return nil          // not ours — let the other engines see it
        case .none:
            return nil
        }
    }
}
