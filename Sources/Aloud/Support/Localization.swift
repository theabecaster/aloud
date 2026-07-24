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
    // The module bundle, exposed so tests can load individual .lproj tables.
    //
    // Resolved by hand, NOT via Bundle.module: SwiftPM's generated accessor
    // for an executable target only looks at the bundle ROOT and the absolute
    // path of the machine that compiled it, then fatalErrors. Inside a .app
    // the resources live in Contents/Resources (staged by make-app.sh), so
    // v2.0.0 crashed on every localized string on machines without the CI
    // build directory. Missing bundle degrades to English (keys are the
    // English text) — never to a crash.
    private final class BundleFinder {}

    static let bundle: Bundle = {
        let name = "Aloud_Aloud.bundle"
        let candidates: [URL?] = [
            Bundle.main.resourceURL,                                  // .app: Contents/Resources
            Bundle(for: BundleFinder.self).resourceURL,               // frameworks-style layouts
            // Tests: the .xctest bundle sits in the build dir, next to the
            // resource bundle — its parent is where to look.
            Bundle(for: BundleFinder.self).bundleURL.deletingLastPathComponent(),
            Bundle.main.executableURL?.deletingLastPathComponent(),   // bare `swift build` binary
            Bundle.main.bundleURL,                                    // SwiftPM's own guess
        ]
        for base in candidates {
            if let url = base?.appendingPathComponent(name), let found = Bundle(url: url) {
                return found
            }
        }
        return .main
    }()
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
