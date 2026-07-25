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
    case none
}

// Pure state machine: feed it event type + keycode + flags, get an action.
//
// Modes:
//   hold: press → .begin … release ≥ minimumHold → .commit (shorter → .cancel)
//   hands-free (optional): two quick taps → second release yields .lock
//     (recording, begun on the second press, continues); another double-tap
//     or Esc finishes → .commit. Single presses while locked are ignored.
//   Esc while *holding* cancels.
struct HotkeyEngine {
    var hotkey: Hotkey
    // When false, double-pressing never locks — the key only works while held.
    var handsFreeEnabled: Bool
    private(set) var isHeld = false
    private(set) var isLocked = false
    private var pressTime: TimeInterval = 0
    private var lastTapTime: TimeInterval = -1

    // Holds shorter than this are accidental taps — recording still starts
    // instantly on press; the *commit* is suppressed for sub-threshold holds.
    static let minimumHold: TimeInterval = 0.15
    // Two taps within this window arm hands-free mode.
    static let doubleTapWindow: TimeInterval = 0.4

    init(hotkey: Hotkey, handsFreeEnabled: Bool = true) {
        self.hotkey = hotkey
        self.handsFreeEnabled = handsFreeEnabled
    }

    // Back to idle, forgetting any held/locked state and pending double-tap.
    mutating func reset() {
        isHeld = false
        isLocked = false
        lastTapTime = -1
    }

    // Jump straight to a hands-free session (the dedicated hands-free key
    // skips the double-tap dance). Caller emits .begin/.lock itself.
    mutating func forceLock() {
        isHeld = false
        isLocked = true
        lastTapTime = -1
    }

    mutating func handle(type: CGEventType, keyCode: UInt16, flags: CGEventFlags,
                         time: TimeInterval) -> HotkeyAction {
        switch type {
        case .flagsChanged:
            guard hotkey.isModifierKey, keyCode == hotkey.keyCode, let flag = hotkey.modifierFlag else { return .none }
            let nowDown = flags.contains(flag)
            if nowDown && !isHeld {
                return press(time: time)
            } else if !nowDown && isHeld {
                return release(time: time)
            }
            return .none

        case .otherMouseDown:
            guard hotkey.isMouseButton, keyCode == hotkey.keyCode, !isHeld else { return .none }
            return press(time: time)

        case .otherMouseUp:
            guard hotkey.isMouseButton, keyCode == hotkey.keyCode, isHeld else { return .none }
            return release(time: time)

        case .keyDown:
            if keyCode == UInt16(kVK_Escape), isHeld || isLocked {
                // Esc finishes a hands-free session (all that dictation should
                // type, not vanish) but discards a held one.
                let wasLocked = isLocked
                isHeld = false; isLocked = false; lastTapTime = -1
                return wasLocked ? .commit : .cancel
            }
            guard !hotkey.isModifierKey, !hotkey.isMouseButton, keyCode == hotkey.keyCode, !isHeld,
                  flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).rawValue
                    == CGEventFlags(rawValue: hotkey.modifiers).intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).rawValue
            else { return .none }
            return press(time: time)

        case .keyUp:
            guard !hotkey.isModifierKey, !hotkey.isMouseButton, keyCode == hotkey.keyCode, isHeld
            else { return .none }
            return release(time: time)

        default:
            return .none
        }
    }

    private mutating func press(time: TimeInterval) -> HotkeyAction {
        if isLocked {
            // Double-tapping the hotkey again ends hands-free, mirroring how it
            // began. isHeld stays false so this press's release is swallowed and
            // lastTapTime is cleared so the pair can't re-arm a new session.
            if lastTapTime >= 0, (time - lastTapTime) <= Self.doubleTapWindow {
                isLocked = false
                isHeld = false
                lastTapTime = -1
                return .commit
            }
            isHeld = true
            pressTime = time
            lastTapTime = time
            return .none
        }
        isHeld = true
        pressTime = time
        return .begin
    }

    private mutating func release(time: TimeInterval) -> HotkeyAction {
        isHeld = false
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

final class HotkeyManager {
    var onAction: ((HotkeyAction) -> Void)?

    private var engine: HotkeyEngine
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

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

    // Optional dedicated hands-free key: one press starts a locked session,
    // another finishes it. Handled ahead of the engine; ignored when it
    // duplicates the main key.
    var handsFreeHotkey: Hotkey?
    private var handsFreeModifierWasDown = false

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
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.handleTapEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
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

    private func handleTapEvent(type: CGEventType, event: CGEvent) {
        // macOS disables taps that stall or on timeout — re-enable transparently.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
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

        if let action = handsFreeKeyAction(type: type, keyCode: keyCode, flags: event.flags) {
            if action != .none {
                DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
            }
            return
        }

        // Command key next: its engine only ever consumes its own key (and Esc
        // during a command hold); anything else returns .none and falls through.
        if commandEngine != nil, commandHotkey != engine.hotkey {
            let commandAction = commandEngine?.handle(
                type: type, keyCode: keyCode, flags: event.flags,
                time: time) ?? .none
            if commandAction != .none {
                DispatchQueue.main.async { [weak self] in self?.onAction?(commandAction) }
                return
            }
        }

        let action = engine.handle(type: type, keyCode: keyCode, flags: event.flags,
                                   time: time)
        if action != .none {
            DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
        }
    }

    // Detect a press of the dedicated hands-free key. Returns nil when the
    // event isn't ours (fall through to the engine); .none swallows a release.
    private func handsFreeKeyAction(type: CGEventType, keyCode: UInt16,
                                    flags: CGEventFlags) -> HotkeyAction? {
        guard let hk = handsFreeHotkey, hk != engine.hotkey else { return nil }
        let pressed: Bool
        switch type {
        case .otherMouseDown where hk.isMouseButton && keyCode == hk.keyCode:
            pressed = true
        case .otherMouseUp where hk.isMouseButton && keyCode == hk.keyCode:
            return HotkeyAction.none
        case .keyDown where !hk.isModifierKey && !hk.isMouseButton && keyCode == hk.keyCode:
            let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            guard flags.intersection(relevant).rawValue
                    == CGEventFlags(rawValue: hk.modifiers).intersection(relevant).rawValue
            else { return nil }
            pressed = true
        case .keyUp where !hk.isModifierKey && !hk.isMouseButton && keyCode == hk.keyCode:
            return HotkeyAction.none
        case .flagsChanged where hk.isModifierKey && keyCode == hk.keyCode:
            guard let flag = hk.modifierFlag else { return nil }
            let nowDown = flags.contains(flag)
            defer { handsFreeModifierWasDown = nowDown }
            guard nowDown, !handsFreeModifierWasDown else { return HotkeyAction.none }
            pressed = true
        default:
            return nil
        }
        guard pressed else { return HotkeyAction.none }
        // A session in any state ends; idle begins a locked one.
        if engine.isLocked || engine.isHeld {
            engine.reset()
            return .commit
        }
        engine.forceLock()
        DispatchQueue.main.async { [weak self] in self?.onAction?(.begin) }
        return .lock
    }
}
