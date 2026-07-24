import Foundation

// Per-app dictation modes: where the text is going shapes how the Concise
// rewrite tightens it. A chat message should stay casual, an email should read
// professionally, a note should keep its detail. Resolution is pure logic over
// the session app's bundle ID so it is unit-testable without AppKit.
enum DictationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case messaging, email, notes, code, general

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .messaging: return loc("Messaging")
        case .email: return loc("Email")
        case .notes: return loc("Notes")
        case .code: return loc("Code")
        case .general: return loc("General")
        }
    }

    // Whether the Concise rewrite may run at all. Dictation into a terminal
    // or editor becomes commands, code, and commit messages — creatively
    // rewording those is never safe, so code apps get deterministic polish
    // only, whatever the clean-up level says.
    var allowsRewrite: Bool { self != .code }

    // Appended to the rewrite engine's instructions when the Concise level
    // runs. Short and factual on purpose — they steer tone, nothing else.
    var toneInstruction: String? {
        switch self {
        case .messaging: return "The text is a chat message: keep it casual and short. Keep questions as questions."
        case .email: return "Use a professional, clear tone with full sentences. Keep the speaker's questions and requests aimed at the reader. Still no greetings or sign-offs."
        case .notes: return "The text is a note: tighten it like normal, keep the key details, and use a short list when it enumerates items or steps."
        case .code, .general: return nil
        }
    }

    // Curated table of well-known apps. Keys are lowercased; lookups
    // lowercase the incoming bundle ID so casing never matters.
    private static let builtInTable: [String: DictationMode] = [
        // Messaging
        "com.apple.mobilesms": .messaging,           // Messages
        "com.tinyspeck.slackmacgap": .messaging,     // Slack
        "com.hnc.discord": .messaging,               // Discord
        "ru.keepcoder.telegram": .messaging,         // Telegram
        "net.whatsapp.whatsapp": .messaging,         // WhatsApp
        // Email
        "com.apple.mail": .email,                    // Mail
        "com.microsoft.outlook": .email,             // Outlook
        "com.readdle.sparkdesktop": .email,          // Spark
        // Notes
        "com.apple.notes": .notes,                   // Notes
        "md.obsidian": .notes,                       // Obsidian
        "net.shinyfrog.bear": .notes,                // Bear
        "notion.id": .notes,                         // Notion
        // Code / terminals
        "com.apple.terminal": .code,                 // Terminal
        "com.googlecode.iterm2": .code,              // iTerm2
        "com.mitchellh.ghostty": .code,              // Ghostty
        "dev.warp.warp-stable": .code,               // Warp
        "com.microsoft.vscode": .code,               // VS Code
        "com.todesktop.230313mzl4w4u92": .code,      // Cursor
        "com.apple.dt.xcode": .code,                 // Xcode
    ]

    // App families that share a bundle-ID prefix.
    private static let builtInPrefixes: [(prefix: String, mode: DictationMode)] = [
        ("com.jetbrains.", .code),
    ]

    // The built-in category for an app, .general when it isn't in the table.
    static func builtIn(forBundleID bundleID: String?) -> DictationMode {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return .general }
        if let mode = builtInTable[id] { return mode }
        if let family = builtInPrefixes.first(where: { id.hasPrefix($0.prefix) }) { return family.mode }
        return .general
    }
}
