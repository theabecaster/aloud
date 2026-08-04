import Foundation

/// Stderr diagnostics for the seams that have shipped broken while looking
/// fine — consent, listening, the Concise rewrite, harness installs. They
/// exist because every bug found by hand in Agent Speak was a path that did
/// nothing and said nothing; a note here is what made them findable.
///
/// Compiled out of distributed bundles with the rest of the development CLI
/// surface (`make-app.sh` passes `-DALOUD_PROD_CLI` unless `ALOUD_DEV_CLI=1`):
/// a shipped app printing its consent decisions to stderr is a diagnostic in
/// the wrong hands, and the packaging flag is already the line between "this
/// build is for working on Aloud" and "this build is for using it".
enum DevDiag {
    static func note(_ tag: String, _ message: String) {
        #if !ALOUD_PROD_CLI
        FileHandle.standardError.write(Data("[\(tag)] \(message)\n".utf8))
        #endif
    }
}
