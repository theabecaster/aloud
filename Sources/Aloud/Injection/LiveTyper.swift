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

// Stamped on every synthetic keyboard event Aloud posts, so our own event
// monitors can tell them apart from real user input.
enum SyntheticEvent {
    static let marker: Int64 = 0x414C4F5544 // "ALOUD"
}

// Not thread-safe by design: the controller drives it from the main actor.
final class LiveTyper {
    // What we believe sits between the anchor point and the cursor. Only
    // trustworthy while the user leaves the cursor alone — see `rebase()`.
    private(set) var typed = ""

    // Leading transcript characters surrendered to the user: once they click
    // or type mid-dictation, text already on screen is out of reach
    // (backspacing from the new cursor position would eat the wrong
    // characters). Applies skip this many characters of the target and only
    // sync the tail at the current cursor position.
    private(set) var anchorCount = 0

    // Event posting is injectable so tests/selftest can run headless.
    private let postEvents: Bool

    init(postEvents: Bool = true) {
        self.postEvents = postEvents
    }

    func reset() {
        typed = ""
        anchorCount = 0
    }

    // The user moved the cursor or edited: give up on everything typed so
    // far and keep dictation flowing at wherever the cursor is now.
    func rebase() {
        anchorCount += typed.count
        typed = ""
    }

    // Sync the target field with `target`, skipping any rebased-away prefix.
    func apply(_ target: String) {
        let tail = anchorCount > 0 ? String(target.dropFirst(anchorCount)) : target
        guard tail != typed else { return }
        let diff = TypedTextDiff.from(typed, to: tail)
        if postEvents {
            Self.postBackspaces(diff.backspaces)
            Self.postText(diff.insertion)
        }
        typed = tail
    }

    // Remove everything we typed since the last rebase (dictation cancelled).
    // Text surrendered by a rebase stays — it's beyond the anchor.
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
        down.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
        up.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func postKey(_ key: CGKeyCode, source: CGEventSource?) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        down.flags = []
        up.flags = []
        down.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
        up.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
