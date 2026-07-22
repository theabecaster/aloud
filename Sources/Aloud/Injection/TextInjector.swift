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

    struct Snapshot {
        let items: [[String: Data]]   // per item: type → data
    }

    func snapshot() -> Snapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item -> [String: Data] in
            var entry: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type.rawValue] = data }
            }
            return entry
        }
        return Snapshot(items: items)
    }

    func restore(_ snapshot: Snapshot) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let items = snapshot.items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    // Restore delay: long enough for the target app to service the paste,
    // short enough that the user won't notice their clipboard "flicker".
    static let restoreDelay: TimeInterval = 0.8

    func inject(_ text: String, completion: (() -> Void)? = nil) {
        let saved = snapshot()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if postEvents { Self.postCmdV() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay) { [weak self] in
            self?.restore(saved)
            completion?()
        }
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
