import Foundation

// How an agent's request to listen gets approved.
//
// Confirm-by-voice is the default: it is the only mode that is both hands-free
// and gated, which is the whole point of a feature you use without looking at
// the screen.
//
// Deliberately not user-facing vocabulary. Settings → Agent Speak asks the two
// questions a person actually has — "do I get asked?" and "out loud or on
// screen?" — and SettingsStore folds the answers into one of these cases. Only
// the bridge reads the mode, so nothing here needs a display name.
enum AgentConsentMode: String, Codable, CaseIterable, Identifiable {
    case open             // no prompt; any authorized harness may open the mic
    case confirmOnScreen  // the pill shows accept / deny; nothing until it's clicked
    case confirmByVoice   // Aloud asks out loud and waits to hear accept

    var id: String { rawValue }
}
