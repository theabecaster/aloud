import Foundation

// Watches the user correct a dictation as they type it, instead of reading
// the result back later: the injected text and the cursor position at its end
// are both known the moment a commit lands, so a short stream of ordinary
// editing keys — arrows, backspaces, characters — can be replayed against
// that text to reconstruct exactly what the user made of it. Works in any app
// that takes keyboard input, including the ones whose accessibility trees
// give the read-back path nothing (terminals, most notably).
//
// Deliberately fragile: the model only stays live while every incoming event
// is one it can replay perfectly. Anything else — a mouse click, a command
// chord, a Return that might submit, an arrow that leaves the injected span —
// freezes it at the last provably-correct state. Edits made before the freeze
// are genuine and still count; nothing after is guessed at. A wrong
// reconstruction would feed the learner a fabricated correction, and a missed
// one costs a single observation, so every ambiguity resolves to freezing.
//
// Pure logic, no AppKit: the controller adapts NSEvents into `Input`s, which
// keeps every rule here testable without a keyboard.
struct EditTracker {

    // The editing vocabulary the model can replay. Everything else arrives
    // as `.other` and freezes tracking.
    enum Input: Equatable {
        case text(String)        // ordinary typing (shift allowed)
        case backspace
        case forwardDelete
        case left, right         // plain arrows
        case shiftLeft, shiftRight
        case other               // clicks, chords, Return, Tab, Esc, ↑↓, …
    }

    enum State: Equatable {
        case tracking
        case frozen   // saw something unreplayable; text below is final
    }

    private(set) var state: State = .tracking

    // The injected text as the user sees it, mutated in place by each replayed
    // event. Grapheme clusters, matching how one Delete press behaves.
    private var chars: [Character]
    // Cursor position within (and only within) the injected text. Leaving the
    // span in either direction means editing text this model has never seen.
    private var cursor: Int
    // Non-nil while a shift-selection is being dragged out; its own position
    // is the fixed end, `cursor` the moving one.
    private var anchor: Int?

    private let original: String

    init(injected: String) {
        original = injected
        chars = Array(injected)
        cursor = chars.count   // a fresh injection leaves the caret at its end
    }

    // The reconstructed text — the injected span as the user has edited it.
    var text: String { String(chars) }

    // Whether the user actually changed anything. `text` alone can't say:
    // a deletion followed by retyping the same characters must not count.
    var edited: Bool { text != original }

    private var selection: Range<Int>? {
        guard let anchor, anchor != cursor else { return nil }
        return min(anchor, cursor)..<max(anchor, cursor)
    }

    // Replay one event. Returns the state afterwards so callers can stop
    // feeding a frozen model.
    @discardableResult
    mutating func consume(_ input: Input) -> State {
        guard state == .tracking else { return state }
        switch input {
        case .text(let typed):
            // Keystrokes that carry no insertable text — dead keys
            // mid-compose, control characters, the function keys AppKit
            // reports as U+F700–F8FF — leave the field in a state this
            // replay can't see.
            guard !typed.isEmpty,
                  !typed.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value)
                  })
            else { return freeze() }
            replaceSelection(with: Array(typed))
        case .backspace:
            if let selection {
                delete(selection)
            } else if cursor > 0 {
                chars.remove(at: cursor - 1)
                cursor -= 1
            } else {
                return freeze()   // deleting into text before the injection
            }
        case .forwardDelete:
            if let selection {
                delete(selection)
            } else if cursor < chars.count {
                chars.remove(at: cursor)
            } else {
                return freeze()   // deleting into text after the injection
            }
        case .left:
            if let selection { cursor = selection.lowerBound; anchor = nil }
            else if cursor > 0 { cursor -= 1 }
            else { return freeze() }
        case .right:
            if let selection { cursor = selection.upperBound; anchor = nil }
            else if cursor < chars.count { cursor += 1 }
            else { return freeze() }
        case .shiftLeft:
            guard cursor > 0 else { return freeze() }
            if anchor == nil { anchor = cursor }
            cursor -= 1
            if anchor == cursor { anchor = nil }
        case .shiftRight:
            guard cursor < chars.count else { return freeze() }
            if anchor == nil { anchor = cursor }
            cursor += 1
            if anchor == cursor { anchor = nil }
        case .other:
            return freeze()
        }
        return state
    }

    private mutating func replaceSelection(with typed: [Character]) {
        if let selection {
            chars.replaceSubrange(selection, with: typed)
            cursor = selection.lowerBound + typed.count
            anchor = nil
        } else {
            chars.insert(contentsOf: typed, at: cursor)
            cursor += typed.count
        }
    }

    private mutating func delete(_ range: Range<Int>) {
        chars.removeSubrange(range)
        cursor = range.lowerBound
        anchor = nil
    }

    private mutating func freeze() -> State {
        state = .frozen
        anchor = nil
        return state
    }
}
