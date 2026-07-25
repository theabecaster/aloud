import AppKit
import Carbon.HIToolbox

// A push-to-talk key: a lone modifier (held), a chord of two or three
// modifiers (held together), or a regular key / extra mouse button, optionally
// with required modifier flags. Persisted in UserDefaults as JSON.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64        // CGEventFlags rawValue; 0 for lone modifiers, chord mask for modifier chords
    var isModifierKey: Bool      // true → track via flagsChanged (e.g. right ⌘, or a ⌃⌥ chord)
    var isMouseButton: Bool      // true → keyCode is a mouse button number (3rd button and up)

    init(keyCode: UInt16, modifiers: UInt64, isModifierKey: Bool, isMouseButton: Bool = false) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isModifierKey = isModifierKey
        self.isMouseButton = isMouseButton
    }

    // isMouseButton arrived after 1.3 shipped — decode older persisted hotkeys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decode(UInt16.self, forKey: .keyCode)
        modifiers = try c.decode(UInt64.self, forKey: .modifiers)
        isModifierKey = try c.decode(Bool.self, forKey: .isModifierKey)
        isMouseButton = try c.decodeIfPresent(Bool.self, forKey: .isMouseButton) ?? false
    }

    // The four modifiers a chord can be built from. fn stays out: it is
    // system-reserved (dictation/emoji) and behaves erratically in combos.
    static let chordable: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

    // A chord of two or three modifiers held together. Chords are
    // side-insensitive (either ⌃ works); the stored keyCode is a canonical
    // stand-in so equality and legacy pathways stay well-defined.
    static func chord(_ flags: CGEventFlags) -> Hotkey {
        let mask = flags.intersection(chordable)
        return Hotkey(keyCode: canonicalKeyCode(for: mask), modifiers: mask.rawValue, isModifierKey: true)
    }

    private static func canonicalKeyCode(for mask: CGEventFlags) -> UInt16 {
        if mask.contains(.maskControl) { return UInt16(kVK_Control) }
        if mask.contains(.maskAlternate) { return UInt16(kVK_Option) }
        if mask.contains(.maskShift) { return UInt16(kVK_Shift) }
        return UInt16(kVK_Command)
    }

    // Defaults: Control pairs. Control is the one modifier macOS text editing
    // never holds together with another (⌥/⌘/⇧ pairs all steer the cursor or
    // selection), so these stay out of the way of word-jumps, line-jumps, and
    // shift-selection. One family, one story: Control plus a neighbor talks
    // to Aloud.
    static let `default` = Hotkey.chord([.maskControl, .maskAlternate])
    static let defaultHandsFreeKey = Hotkey.chord([.maskControl, .maskShift])
    static let defaultCommandKey = Hotkey.chord([.maskControl, .maskCommand])

    // A modifier chord (⌃⌥) rather than a single tracked modifier key.
    var isChord: Bool { isModifierKey && modifiers != 0 }

    // All modifiers that must be down for a chord hotkey.
    var chordMask: CGEventFlags { CGEventFlags(rawValue: modifiers).intersection(Self.chordable) }

    // The CGEventFlags bit a lone-modifier hotkey toggles, used to detect hold/release.
    var modifierFlag: CGEventFlags? {
        guard isModifierKey, !isChord else { return nil }
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand: return .maskCommand
        case kVK_Option, kVK_RightOption: return .maskAlternate
        case kVK_Control, kVK_RightControl: return .maskControl
        case kVK_Shift, kVK_RightShift: return .maskShift
        case kVK_Function: return .maskSecondaryFn
        default: return nil
        }
    }

    // How many keys the user physically holds: chord members, plus the
    // regular key or mouse button if there is one.
    var memberCount: Int {
        let flagCount = memberFlags.rawValue.nonzeroBitCount
        return isModifierKey ? max(flagCount, 1) : flagCount + 1
    }

    // The modifier flags this hotkey involves, side-insensitive.
    private var memberFlags: CGEventFlags {
        if isChord { return chordMask }
        if isModifierKey { return modifierFlag?.intersection(Self.chordable) ?? [] }
        return CGEventFlags(rawValue: modifiers).intersection(Self.chordable)
    }

    // True when every key of `other` is also part of self (or vice versa
    // checked by the caller) — pressing the bigger combo necessarily passes
    // through the smaller one, so the two can't coexist. Two lone modifiers
    // on different physical keys (Left ⌥ vs Right ⌥) never conflict: the
    // engine tells them apart by keycode.
    func overlaps(_ other: Hotkey) -> Bool {
        if self == other { return true }
        if isModifierKey, !isChord, other.isModifierKey, !other.isChord {
            return keyCode == other.keyCode
        }
        return covers(other) || other.covers(self)
    }

    // Every member of `other` is contained in self.
    func covers(_ other: Hotkey) -> Bool {
        guard other.memberFlags.isSubset(of: memberFlags) else { return false }
        if other.isModifierKey { return !other.memberFlags.isEmpty }  // pure-modifier subset (fn tracks by keycode only)
        // A terminal key/button must match exactly to be contained.
        return other.isMouseButton == isMouseButton
            && !isModifierKey
            && other.keyCode == keyCode
    }

    var displayName: String {
        if isChord { return Self.glyphs(for: chordMask) }
        let mods = CGEventFlags(rawValue: modifiers)
        let prefix = Self.glyphs(for: mods)
        if isMouseButton {
            let name = loc("Mouse %ld", Int(keyCode) + 1)
            return prefix.isEmpty ? name : "\(prefix) \(name)"
        }
        return prefix + Hotkey.keyName(for: keyCode)
    }

    // Standard macOS ordering: ⌃ ⌥ ⇧ ⌘.
    static func glyphs(for mods: CGEventFlags) -> String {
        var parts: [String] = []
        if mods.contains(.maskControl) { parts.append("⌃") }
        if mods.contains(.maskAlternate) { parts.append("⌥") }
        if mods.contains(.maskShift) { parts.append("⇧") }
        if mods.contains(.maskCommand) { parts.append("⌘") }
        return parts.joined()
    }

    static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Command: return loc("Left ⌘")
        case kVK_RightCommand: return loc("Right ⌘")
        case kVK_Option: return loc("Left ⌥")
        case kVK_RightOption: return loc("Right ⌥")
        case kVK_Control: return loc("Left ⌃")
        case kVK_RightControl: return loc("Right ⌃")
        case kVK_Shift: return loc("Left ⇧")
        case kVK_RightShift: return loc("Right ⇧")
        case kVK_Function: return "fn"
        case kVK_Space: return loc("Space")
        // F-key virtual keycodes are not contiguous (kVK_F1 = 0x7A > kVK_F20 = 0x5A),
        // so a range pattern over them would trap at runtime.
        case let code where fKeyNames[code] != nil: return fKeyNames[code]!
        default:
            // Translate via the current keyboard layout.
            if let s = Hotkey.characters(for: keyCode), !s.isEmpty { return s.uppercased() }
            return loc("key %ld", Int(keyCode))
        }
    }

    private static let fKeyNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static func characters(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let err = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> OSStatus in
            let layout = buf.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, chars.count, &length, &chars)
        }
        guard err == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
