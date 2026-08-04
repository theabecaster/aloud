import AppKit
import Carbon.HIToolbox

// Puts transcribed text into whatever app is focused: snapshot the pasteboard,
// write our text, post a synthetic ⌘V, then restore the user's clipboard.
//
// The pasteboard round-trip is the only injection method that works across
// every app (AX text insertion fails in Electron/web views). Restore happens
// after a short delay so the paste has read the board first.
final class TextInjector {
    // Injectable pasteboard for tests/selftest (a private named board there,
    // the general one in production).
    private let pasteboard: NSPasteboard
    private let postEvents: Bool

    init(pasteboard: NSPasteboard = .general, postEvents: Bool = true) {
        self.pasteboard = pasteboard
        self.postEvents = postEvents
    }

    // Flavors are kept as an ordered list, not a dictionary: a pasteboard item
    // advertises its types in priority order and the pasting app takes the
    // first one it understands. A dictionary would re-order them on every
    // restore, so a copied rich-text selection could come back plain-text-first.
    struct Snapshot {
        let items: [[(type: String, data: Data)]]   // per item: flavors, richest first
    }

    func snapshot() -> Snapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type -> (type: String, data: Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type.rawValue, data)
            }
        }
        return Snapshot(items: items)
    }

    func restore(_ snapshot: Snapshot) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let items = snapshot.items.map { flavors -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in flavors {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    // Restore delay: long enough for the target app to service the paste,
    // short enough that the user won't notice their clipboard "flicker".
    static let restoreDelay: TimeInterval = 0.8

    // Injections can overlap: two quick dictations land closer together than
    // the restore delay. Only the newest call's restore may run — an earlier
    // one firing late would clobber the newer paste mid-flight — and the
    // snapshot carried forward is the user's *real* clipboard, not the
    // previous injection's text, which is what the board holds while a
    // restore is still pending. Main-thread confined, like inject itself.
    private var restoreGeneration = 0
    private var pendingOriginal: Snapshot?

    func inject(_ text: String, completion: (() -> Void)? = nil) {
        let saved = pendingOriginal ?? snapshot()
        pendingOriginal = saved
        restoreGeneration += 1
        let generation = restoreGeneration
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if postEvents { Self.postCmdV() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay) { [weak self] in
            if let self, generation == self.restoreGeneration {
                self.restore(saved)
                self.pendingOriginal = nil
            }
            completion?()
        }
    }

    // A synthetic Return, for the "press enter" voice command. Same marker as
    // every other event we post so our own monitors ignore it.
    static func postReturn() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_Return)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        down.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
        up.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func postCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else { return }
        down.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
        up.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
