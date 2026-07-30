import Foundation

// Watches the user correct a dictation as they type it, instead of reading
// the result back later: the injected text and the cursor position at its end
// are both known the moment a commit lands, so the stream of editing keys can
// be interpreted against that text. Works in any app that takes keyboard
// input, including the ones whose accessibility trees give the read-back
// path nothing (terminals, most notably).
//
// Two phases, degrading rather than giving up:
//
// - **Exact**: every event so far is replayable perfectly — arrows,
//   backspaces, characters, shift-selections — so the model knows the edited
//   text outright.
// - **Approximate**: the cursor went somewhere unknowable (a click, ↑/↓,
//   leaving the injected span). Individual keys can no longer be placed, but
//   what the user *types* between cursor jumps is still knowable — each such
//   burst is collected verbatim, and the conclusion fuzzy-matches it against
//   the injected words (CorrectionGuess). "Double-click a word, retype it"
//   lands here, and it is the most common correction gesture there is.
//
// Anything that could change text in ways typing can't describe — command
// chords (paste, select-all), a Return that might submit, a dead key mid-
// compose — ends tracking outright at the last trustworthy state. A wrong
// reconstruction would feed the learner a fabricated correction; a missed
// one costs a single observation. Every ambiguity resolves toward less.
//
// Pure logic, no AppKit: the controller adapts NSEvents into `Input`s, which
// keeps every rule here testable without a keyboard.
struct EditTracker {

    enum Input: Equatable {
        case text(String)        // ordinary typing (shift allowed)
        case backspace
        case forwardDelete
        case left, right         // plain arrows
        case shiftLeft, shiftRight
        case click               // mouse down — cursor now unknowable
        case nav                 // ↑ ↓ Home End PgUp PgDn — same, by key
        case other               // chords, Return, Tab, Esc — end tracking
    }

    enum Phase: Equatable {
        case exact         // the edited text is known outright
        case approximate   // collecting typed bursts at unknown positions
        case done          // saw something that could falsify both models
    }

    private(set) var phase: Phase = .exact

    // What the conclusion has to work with: the exactly-known text (as far
    // as the exact phase got) plus every burst typed after positions became
    // unknowable. Bursts carry no position — only a unique fuzzy match
    // against the injection may turn one into a correction.
    struct Outcome: Equatable {
        let exactText: String
        let exactEdited: Bool
        let bursts: [String]
    }

    // MARK: exact-phase model

    // The injected text as the user sees it, mutated in place by each
    // replayed event. Grapheme clusters, matching how one Delete behaves.
    private var chars: [Character]
    // Cursor position within (and only within) the injected text. Leaving
    // the span means editing text this model has never seen — approximate
    // from there on.
    private var cursor: Int
    // Non-nil while a shift-selection is being dragged out; its own position
    // is the fixed end, `cursor` the moving one.
    private var anchor: Int?

    private let original: String

    // MARK: approximate-phase model

    private var bursts: [String] = []
    private var burst: [Character] = []
    // A user still typing after this many cursor jumps is writing, not
    // correcting — and each burst is one more chance to guess wrong.
    static let maxBursts = 8

    init(injected: String) {
        original = injected
        chars = Array(injected)
        cursor = chars.count   // a fresh injection leaves the caret at its end
    }

    var outcome: Outcome {
        let text = String(chars)
        var all = bursts
        if !burst.isEmpty { all.append(String(burst)) }
        return Outcome(exactText: text, exactEdited: text != original, bursts: all)
    }

    private var selection: Range<Int>? {
        guard let anchor, anchor != cursor else { return nil }
        return min(anchor, cursor)..<max(anchor, cursor)
    }

    // Replay one event. Returns the phase afterwards so callers can stop
    // feeding a finished model.
    @discardableResult
    mutating func consume(_ input: Input) -> Phase {
        switch phase {
        case .done: return .done
        case .exact: return consumeExact(input)
        case .approximate: return consumeApproximate(input)
        }
    }

    private mutating func consumeExact(_ input: Input) -> Phase {
        switch input {
        case .text(let typed):
            guard let insertable = Self.insertable(typed) else { return finish() }
            replaceSelection(with: insertable)
        case .backspace:
            if let selection {
                delete(selection)
            } else if cursor > 0 {
                chars.remove(at: cursor - 1)
                cursor -= 1
            } else {
                return demote()   // deleting into text before the injection
            }
        case .forwardDelete:
            if let selection {
                delete(selection)
            } else if cursor < chars.count {
                chars.remove(at: cursor)
            } else {
                return demote()   // deleting into text after the injection
            }
        case .left:
            if let selection { cursor = selection.lowerBound; anchor = nil }
            else if cursor > 0 { cursor -= 1 }
            else { return demote() }
        case .right:
            if let selection { cursor = selection.upperBound; anchor = nil }
            else if cursor < chars.count { cursor += 1 }
            else { return demote() }
        case .shiftLeft:
            guard cursor > 0 else { return demote() }
            if anchor == nil { anchor = cursor }
            cursor -= 1
            if anchor == cursor { anchor = nil }
        case .shiftRight:
            guard cursor < chars.count else { return demote() }
            if anchor == nil { anchor = cursor }
            cursor += 1
            if anchor == cursor { anchor = nil }
        case .click, .nav:
            return demote()
        case .other:
            return finish()
        }
        return phase
    }

    private mutating func consumeApproximate(_ input: Input) -> Phase {
        switch input {
        case .text(let typed):
            guard let insertable = Self.insertable(typed) else { return finish() }
            burst.append(contentsOf: insertable)
        case .backspace:
            // Correcting a typo inside the burst; deletions past its start
            // ate pre-existing text, which costs nothing — the burst is
            // matched by content, not position.
            if !burst.isEmpty { burst.removeLast() }
        case .forwardDelete:
            break   // deletes unknown text; the burst itself is untouched
        case .left, .right, .shiftLeft, .shiftRight, .click, .nav:
            // The cursor moved again: whatever was typed is complete, and
            // the next typing belongs to a new position.
            return pushBurst()
        case .other:
            return finish()
        }
        return phase
    }

    // MARK: shared mechanics

    // Keystrokes that carry no insertable text — dead keys mid-compose,
    // control characters, the function keys AppKit reports as U+F700–F8FF —
    // leave the field in a state no replay can see.
    private static func insertable(_ typed: String) -> [Character]? {
        guard !typed.isEmpty,
              !typed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value)
              })
        else { return nil }
        return Array(typed)
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

    private mutating func demote() -> Phase {
        phase = .approximate
        anchor = nil
        return phase
    }

    private mutating func pushBurst() -> Phase {
        if !burst.isEmpty {
            bursts.append(String(burst))
            burst = []
            if bursts.count >= Self.maxBursts { phase = .done }
        }
        return phase
    }

    private mutating func finish() -> Phase {
        _ = pushBurst()
        phase = .done
        anchor = nil
        return phase
    }
}
