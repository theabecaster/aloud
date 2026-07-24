import Foundation

// A user-defined per-app override (Settings → Modes): pin an app to one of
// the built-in categories, give the rewrite a custom instruction, or demand
// the exact words. Custom rules always beat the built-in table.
struct AppModeRule: Codable, Equatable, Identifiable, Sendable {
    // What the rule does. Codable is hand-written with a stable "kind"
    // discriminator so saved rules survive future additions.
    enum Behavior: Equatable, Sendable {
        case category(DictationMode)   // treat the app as a built-in category
        case custom(String)            // user's own tone instruction
        case verbatim                  // exact words: skip the rewrite
    }

    var id = UUID()
    var appName: String?   // display only; matching is by bundle ID
    var bundleID: String
    var behavior: Behavior

    // Shown in the rules list.
    var summary: String {
        switch behavior {
        case .category(let mode): return mode.displayName
        case .custom(let instruction): return "“\(instruction)”"
        case .verbatim: return "Exact words"
        }
    }
}

extension AppModeRule.Behavior: Codable {
    private enum CodingKeys: String, CodingKey { case kind, category, instruction }
    private enum Kind: String, Codable { case category, custom, verbatim }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .category: self = .category(try container.decode(DictationMode.self, forKey: .category))
        case .custom: self = .custom(try container.decode(String.self, forKey: .instruction))
        case .verbatim: self = .verbatim
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .category(let mode):
            try container.encode(Kind.category, forKey: .kind)
            try container.encode(mode, forKey: .category)
        case .custom(let instruction):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(instruction, forKey: .instruction)
        case .verbatim:
            try container.encode(Kind.verbatim, forKey: .kind)
        }
    }
}

// What the commit pipeline needs to know about a session app, resolved once
// per dictation: may the Concise rewrite run, and with what tone.
struct ModeDecision: Equatable, Sendable {
    var allowsRewrite: Bool
    var extraInstructions: String?
}

// Pure resolution: the user's rules first (exact bundle-ID match, case
// doesn't matter), the built-in table otherwise.
enum ModeResolver {
    static func decision(forBundleID bundleID: String?, rules: [AppModeRule]) -> ModeDecision {
        if let id = bundleID?.lowercased(), !id.isEmpty,
           let rule = rules.first(where: { $0.bundleID.lowercased() == id }) {
            switch rule.behavior {
            case .category(let mode):
                return decision(for: mode)
            case .custom(let instruction):
                let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
                return ModeDecision(allowsRewrite: true,
                                    extraInstructions: trimmed.isEmpty ? nil : trimmed)
            case .verbatim:
                return ModeDecision(allowsRewrite: false, extraInstructions: nil)
            }
        }
        return decision(for: DictationMode.builtIn(forBundleID: bundleID))
    }

    static func decision(for mode: DictationMode) -> ModeDecision {
        ModeDecision(allowsRewrite: mode.allowsRewrite, extraInstructions: mode.toneInstruction)
    }
}
