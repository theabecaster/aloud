import AppKit
import Carbon.HIToolbox

// Live-typing writer: keeps the focused app's text in sync with an evolving
// transcript by typing only the difference — backspaces to rewind past the
// point of divergence, then synthetic keystrokes for the new tail.
//
// Unlike TextInjector this never touches the clipboard: text is delivered via
// CGEvent unicode-string keystrokes, so per-second updates don't fight the
// clipboard-restore window. Every event posts with empty modifier flags —
// during live typing the user is still physically holding the dictation
// hotkey (often a bare modifier like right ⌥), and letting that leak into
// synthetic keystrokes would garble the typed text.

// Pure diff: what it takes to turn `old` into `new` for a text field whose
// cursor sits at the end of `old`. Counts backspaces in grapheme clusters —
// one Delete press removes one cluster.
struct TypedTextDiff: Equatable {
    let backspaces: Int
    let insertion: String

    static func from(_ old: String, to new: String) -> TypedTextDiff {
        let oldChars = Array(old)
        let newChars = Array(new)
        var common = 0
        while common < oldChars.count, common < newChars.count, oldChars[common] == newChars[common] {
            common += 1
        }
        return TypedTextDiff(backspaces: oldChars.count - common,
                             insertion: String(newChars[common...]))
    }
}

// Not thread-safe by design: the controller drives it from the main actor.
final class LiveTyper {
    // What we believe is currently in the target field. Only trustworthy while
    // the user leaves the cursor alone — see `freeze()`.
    private(set) var typed = ""

    // Once frozen (user clicked somewhere mid-dictation) we stop touching the
    // target entirely; edits would land at the wrong cursor position.
    private(set) var isFrozen = false

    // Event posting is injectable so tests/selftest can run headless.
    private let postEvents: Bool

    init(postEvents: Bool = true) {
        self.postEvents = postEvents
    }

    func reset() {
        typed = ""
        isFrozen = false
    }

    func freeze() {
        isFrozen = true
    }

    // Bring the target field from `typed` to `target`.
    func apply(_ target: String) {
        guard !isFrozen, target != typed else { return }
        let diff = TypedTextDiff.from(typed, to: target)
        if postEvents {
            Self.postBackspaces(diff.backspaces)
            Self.postText(diff.insertion)
        }
        typed = target
    }

    // Remove everything we typed (dictation cancelled).
    func eraseAll() {
        apply("")
    }

    // MARK: event synthesis

    private static func postBackspaces(_ count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            postKey(CGKeyCode(kVK_Delete), source: source)
        }
    }

    // Unicode-string keystrokes: a single event carries up to 20 UTF-16 units,
    // so chunk on grapheme boundaries to stay under the limit.
    private static func postText(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        var chunk = ""
        var chunkUnits = 0
        for character in text {
            let units = character.utf16.count
            if chunkUnits + units > 20 {
                postUnicode(chunk, source: source)
                chunk = ""
                chunkUnits = 0
            }
            chunk.append(character)
            chunkUnits += units
        }
        postUnicode(chunk, source: source)
    }

    private static func postUnicode(_ text: String, source: CGEventSource?) {
        guard !text.isEmpty else { return }
        let units = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func postKey(_ key: CGKeyCode, source: CGEventSource?) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
