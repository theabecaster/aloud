import AppKit
import Carbon.HIToolbox

// Global push-to-talk via a CGEventTap.
//
// Listen-only tap on keyDown/keyUp/flagsChanged. A lone-modifier hotkey (the
// default, right ⌘) is tracked through flagsChanged transitions; a regular key
// through keyDown/keyUp with matching modifier flags. Esc while holding cancels.
//
// The decision logic lives in `HotkeyEngine` (pure, event-in/action-out) so the
// selftest can drive it with synthetic events without installing a real tap —
// installing one requires Accessibility, which CI doesn't have.

enum HotkeyAction: Equatable {
    case begin      // key went down → start recording
    case commit     // key released → stop + transcribe
    case cancel     // Esc while held, or accidental tap → discard
    case lock       // double-tap → keep recording hands-free until next tap
    case none
}

// Pure state machine: feed it event type + keycode + flags, get an action.
//
// Modes:
//   hold: press → .begin … release ≥ minimumHold → .commit (shorter → .cancel)
//   hands-free: two quick taps → second release yields .lock (recording, begun
//     on the second press, continues); the next tap of any length → .commit.
//   Esc always cancels.
struct HotkeyEngine {
    var hotkey: Hotkey
    private(set) var isHeld = false
    private(set) var isLocked = false
    private var pressTime: TimeInterval = 0
    private var lastTapTime: TimeInterval = -1

    // Holds shorter than this are accidental taps — recording still starts
    // instantly on press; the *commit* is suppressed for sub-threshold holds.
    static let minimumHold: TimeInterval = 0.15
    // Two taps within this window arm hands-free mode.
    static let doubleTapWindow: TimeInterval = 0.4

    init(hotkey: Hotkey) { self.hotkey = hotkey }

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

        case .keyDown:
            if (isHeld || isLocked) && keyCode == UInt16(kVK_Escape) {
                isHeld = false; isLocked = false; lastTapTime = -1
                return .cancel
            }
            guard !hotkey.isModifierKey, keyCode == hotkey.keyCode, !isHeld,
                  flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).rawValue
                    == CGEventFlags(rawValue: hotkey.modifiers).intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).rawValue
            else { return .none }
            return press(time: time)

        case .keyUp:
            guard !hotkey.isModifierKey, keyCode == hotkey.keyCode, isHeld else { return .none }
            return release(time: time)

        default:
            return .none
        }
    }

    private mutating func press(time: TimeInterval) -> HotkeyAction {
        isHeld = true
        pressTime = time
        // While locked, a press is the "stop" gesture — recording is already on.
        return isLocked ? .none : .begin
    }

    private mutating func release(time: TimeInterval) -> HotkeyAction {
        isHeld = false
        if isLocked {                       // any tap while locked stops + commits
            isLocked = false
            lastTapTime = -1
            return .commit
        }
        if (time - pressTime) >= Self.minimumHold {
            lastTapTime = -1
            return .commit
        }
        // Short tap: second one inside the window locks hands-free (recording
        // already started on this press); a lone one is an accidental cancel.
        if lastTapTime >= 0, (time - lastTapTime) <= Self.doubleTapWindow {
            isLocked = true
            lastTapTime = -1
            return .lock
        }
        lastTapTime = time
        return .cancel
    }
}

final class HotkeyManager {
    var onAction: ((HotkeyAction) -> Void)?

    private var engine: HotkeyEngine
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(hotkey: Hotkey) {
        engine = HotkeyEngine(hotkey: hotkey)
    }

    var hotkey: Hotkey {
        get { engine.hotkey }
        set { engine = HotkeyEngine(hotkey: newValue) }
    }

    // Returns false when the tap can't be created (Accessibility not granted).
    @discardableResult
    func start() -> Bool {
        stop()
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
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
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let action = engine.handle(type: type, keyCode: keyCode, flags: event.flags,
                                   time: ProcessInfo.processInfo.systemUptime)
        if action != .none {
            DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
        }
    }
}
