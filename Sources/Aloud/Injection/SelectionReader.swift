import ApplicationServices

// Reads the selected text of the focused UI element via Accessibility, for
// voice commands that edit "this". Best-effort by design: plenty of apps
// (Electron, some web views) don't expose kAXSelectedTextAttribute — nil just
// means "no selection", and the command falls back to writing at the cursor.
enum SelectionReader {
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
