import AppKit
import Carbon.HIToolbox

// A push-to-talk key: either a lone modifier (held) or a regular key (held),
// optionally with required modifier flags. Persisted in UserDefaults as JSON.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64        // CGEventFlags rawValue for non-modifier keys; 0 for lone modifiers
    var isModifierKey: Bool      // true → track via flagsChanged (e.g. right ⌘)

    // Default: hold right Command. Fn is system-reserved (dictation/emoji) and
    // F-keys collide with media keys, so a lone right-side modifier is the
    // least-surprising default that works on every keyboard.
    static let `default` = Hotkey(keyCode: 54, modifiers: 0, isModifierKey: true)

    // The CGEventFlags bit a lone-modifier hotkey toggles, used to detect hold/release.
    var modifierFlag: CGEventFlags? {
        guard isModifierKey else { return nil }
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand: return .maskCommand
        case kVK_Option, kVK_RightOption: return .maskAlternate
        case kVK_Control, kVK_RightControl: return .maskControl
        case kVK_Shift, kVK_RightShift: return .maskShift
        case kVK_Function: return .maskSecondaryFn
        default: return nil
        }
    }

    var displayName: String {
        let mods = CGEventFlags(rawValue: modifiers)
        var parts: [String] = []
        if mods.contains(.maskControl) { parts.append("⌃") }
        if mods.contains(.maskAlternate) { parts.append("⌥") }
        if mods.contains(.maskShift) { parts.append("⇧") }
        if mods.contains(.maskCommand) { parts.append("⌘") }
        parts.append(Hotkey.keyName(for: keyCode))
        return parts.joined()
    }

    static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Command: return "⌘ (left)"
        case kVK_RightCommand: return "⌘ (right)"
        case kVK_Option: return "⌥ (left)"
        case kVK_RightOption: return "⌥ (right)"
        case kVK_Control: return "⌃ (left)"
        case kVK_RightControl: return "⌃ (right)"
        case kVK_Shift: return "⇧ (left)"
        case kVK_RightShift: return "⇧ (right)"
        case kVK_Function: return "fn"
        case kVK_Space: return "Space"
        case kVK_F1...kVK_F20 where fKeyNames[Int(keyCode)] != nil: return fKeyNames[Int(keyCode)]!
        default:
            // Translate via the current keyboard layout.
            if let s = Hotkey.characters(for: keyCode), !s.isEmpty { return s.uppercased() }
            return "key \(keyCode)"
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
