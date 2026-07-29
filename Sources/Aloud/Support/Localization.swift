import Foundation

// User-facing strings live in the module resource bundle, one classic
// Localizable.strings per language (en is the base; es, de, fr, pt-BR are
// full translations). Classic .strings on purpose: `swift build` copies a
// String Catalog (.xcstrings) into the bundle without compiling it, so keys
// would never resolve — .lproj/.strings work everywhere, including the bare
// CLI binary and the packaged .app.
//
// Keys are the English text. The en table repeats them as values so English
// is an explicit localization, not a fallback accident.
enum L10n {
    // The module bundle (see ModuleResources for why it's hand-resolved),
    // exposed so tests can load individual .lproj tables. A missing bundle
    // degrades to English (keys are the English text) — never to a crash.
    static let bundle: Bundle = ModuleResources.bundle
}

/// Looks up a user-facing string in the module's Localizable table.
func loc(_ key: String) -> String {
    L10n.bundle.localizedString(forKey: key, value: nil, table: nil)
}

/// Format variant — the localized value is a format string (%@, %ld, %%).
/// Translations may reorder arguments with positional specifiers (%1$@).
func loc(_ key: String, _ args: CVarArg...) -> String {
    String(format: loc(key), locale: Locale.current, arguments: args)
}
