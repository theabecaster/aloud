import AppKit
import ApplicationServices
import Carbon.HIToolbox

// Reads the selected text of the focused UI element via Accessibility, for
// voice commands that edit "this". Best-effort by design: plenty of apps
// (Electron, some web views — and notably Notes) don't expose
// kAXSelectedTextAttribute; those fall back to a clipboard round-trip. nil
// still just means "no selection", and the command writes at the cursor.
enum SelectionReader {
    // AX first, then a synthetic ⌘C with the clipboard restored afterwards.
    // The change-count check makes the copy conclusive: no selection → most
    // apps copy nothing → the count doesn't move → nil, not stale clipboard.
    @MainActor
    static func currentSelectionWithFallback() async -> String? {
        if let text = currentSelection() { return text }
        let pasteboard = NSPasteboard.general
        let injector = TextInjector()
        let saved = injector.snapshot()
        let before = pasteboard.changeCount
        postCmdC()
        // Give the focused app a beat to service the copy.
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if pasteboard.changeCount != before { break }
        }
        defer { injector.restore(saved) }
        guard pasteboard.changeCount != before,
              let text = pasteboard.string(forType: .string),
              !text.isEmpty else { return nil }
        return text
    }

    private static func postCmdC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_C)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        down.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
        up.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
    static func currentSelection() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }
        let element = focusedRef as! AXUIElement   // type ID checked above
        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            &selectedRef) == .success,
              let text = selectedRef as? String, !text.isEmpty
        else { return nil }
        return text
    }
}
