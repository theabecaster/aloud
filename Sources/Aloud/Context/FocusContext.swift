import AppKit
import ApplicationServices

// What the user was focused on when dictation started: the frontmost app and,
// when the Accessibility API will say, the text already in the focused field.
// Captured once per session and kept in memory only — nothing here is ever
// persisted or sent anywhere. A later phase consumes it; today it's plumbing.
//
// Every field is optional because AX reads genuinely fail in the wild (many
// Electron apps expose no kAXValueAttribute, secure fields refuse reads), and
// a dictation must start instantly whether or not the field cooperates.
struct FocusSnapshot: Equatable {
    // The app the text will land in — same values DictationController already
    // tracks as sessionApp; carried here so the snapshot is self-contained.
    var appName: String?
    var appBundleID: String?
    // Existing text of the focused field, capped at `textCap` characters
    // around the insertion point (huge documents would be dead weight).
    var fieldText: String?
    var selectedText: String?
    // Selection start/length in the field's own character units, when the
    // field reports one cheaply.
    var selectedRange: Range<Int>?

    static let textCap = 2000

    // Budget for the whole capture: AX calls go through the target app's run
    // loop and an unresponsive app would otherwise stall the start of
    // recording — degrading to an app-only snapshot beats a late session.
    private static let budget: TimeInterval = 0.05
    private static let perCallTimeout: Float = 0.02

    @MainActor
    static func capture(appName: String?, appBundleID: String?) -> FocusSnapshot {
        var snapshot = FocusSnapshot(appName: appName, appBundleID: appBundleID)
        let deadline = Date().addingTimeInterval(budget)

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, perCallTimeout)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return snapshot }
        let focused = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, perCallTimeout)

        // Range first: it's the cheapest read and anchors the text window.
        if let range = copyRange(focused, kAXSelectedTextRangeAttribute) {
            snapshot.selectedRange = range
        }
        guard Date() < deadline else { return snapshot }
        if let value = copyString(focused, kAXValueAttribute) {
            snapshot.fieldText = windowed(value, around: snapshot.selectedRange?.lowerBound)
        }
        guard Date() < deadline else { return snapshot }
        if let selected = copyString(focused, kAXSelectedTextAttribute), !selected.isEmpty {
            snapshot.selectedText = String(selected.prefix(textCap))
        }
        return snapshot
    }

    // Keep at most `cap` characters centered on the insertion point — the text
    // the user is most likely dictating into the middle of. No location means
    // assume the caret is at the end (the common append case).
    static func windowed(_ text: String, around location: Int?, cap: Int = textCap) -> String {
        guard text.count > cap else { return text }
        let chars = Array(text)
        let pivot = min(max(location ?? chars.count, 0), chars.count)
        var start = pivot - cap / 2
        var end = start + cap
        if start < 0 { start = 0; end = cap }
        if end > chars.count { end = chars.count; start = end - cap }
        return String(chars[start..<end])
    }

    // MARK: AX helpers

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    private static func copyRange(_ element: AXUIElement, _ attribute: String) -> Range<Int>? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID()
        else { return nil }
        let value = ref as! AXValue
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range.location..<(range.location + range.length)
    }
}
