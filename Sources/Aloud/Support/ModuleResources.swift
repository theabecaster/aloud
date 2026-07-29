import Foundation

// The module resource bundle (strings, sound cues), resolved by hand —
// NEVER via Bundle.module: SwiftPM's generated accessor for an executable
// target only looks at the bundle ROOT and the absolute build path of the
// machine that compiled it, then fatalErrors. Inside a .app the resources
// live in Contents/Resources (staged by make-app.sh), so any Bundle.module
// call in a release build crashes on every machine but the one that built
// it — v2.0.0 crashed on localized strings, v2.4.0 on the sound cues.
// A missing bundle must always degrade (English text, silent cues), never
// crash.
enum ModuleResources {
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
