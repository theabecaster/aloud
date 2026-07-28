import AppKit
import ApplicationServices

// Best-effort verdict on whether the focused UI element accepts typed text.
enum FieldEditability: Equatable {
    case editable, notEditable, unknown
}

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
    // Whether the focused element looks like it can take typed text. Only
    // `.notEditable` is ever acted on (typing is suppressed) — anything the
    // probe can't classify stays `.unknown` and types as before, because a
    // wrongly withheld dictation is far worse than a stray system beep.
    var editability: FieldEditability = .unknown

    static let textCap = 2000

    // Budget for the whole capture: AX calls go through the target app's run
    // loop and an unresponsive app would otherwise stall the start of
    // recording — degrading to an app-only snapshot beats a late session.
    private static let budget: TimeInterval = 0.05
    private static let perCallTimeout: Float = 0.02

    // Callable off the main actor on purpose: the AX reads can stall for tens
    // of milliseconds, and recording start must never wait on them. The AX C
    // API has no main-thread requirement.
    static func capture(appName: String?, appBundleID: String?) -> FocusSnapshot {
        var snapshot = FocusSnapshot(appName: appName, appBundleID: appBundleID)
        let deadline = Date().addingTimeInterval(budget)

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, perCallTimeout)
        var focusedRef: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(systemWide,
                                                     kAXFocusedUIElementAttribute as CFString,
                                                     &focusedRef)
        guard focusErr == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else {
            // A definitive "nothing has focus" means keystrokes have nowhere
            // to go; timeouts and other errors stay unknown.
            if focusErr == .noValue { snapshot.editability = .notEditable }
            return snapshot
        }
        let focused = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, perCallTimeout)
        snapshot.editability = editability(of: focused)

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

    // MARK: editability

    // Roles that plainly take text; a settable AXValue counts the same way.
    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]
    // Roles that plainly don't. Deliberately short: web areas, groups, and the
    // odd things Electron reports stay unknown rather than risk a false block.
    private static let inertRoles: Set<String> = [
        kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole,
        kAXMenuButtonRole, kAXStaticTextRole, kAXImageRole, kAXListRole,
        kAXTableRole, kAXOutlineRole, kAXScrollAreaRole, kAXToolbarRole,
        kAXMenuItemRole, kAXSliderRole, kAXDisclosureTriangleRole,
    ]

    private static func editability(of element: AXUIElement) -> FieldEditability {
        var role: String?
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref) == .success {
            role = ref as? String
        }
        if let role, textRoles.contains(role) { return .editable }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString,
                                          &settable) == .success, settable.boolValue {
            return .editable
        }
        if let role, inertRoles.contains(role) { return .notEditable }
        return .unknown
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
