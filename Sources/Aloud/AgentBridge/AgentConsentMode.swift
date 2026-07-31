import Foundation

// How an agent's request to listen gets approved.
//
// Chosen on the onboarding install page and changeable in Settings → Agents.
// Confirm-by-voice is the default: it is the only mode that is both hands-free
// and gated, which is the whole point of a feature you use without looking at
// the screen.
enum AgentConsentMode: String, Codable, CaseIterable, Identifiable {
    case open             // no prompt; any authorized harness may open the mic
    case confirmOnScreen  // the pill shows accept / deny; nothing until it's clicked
    case confirmByVoice   // Aloud asks out loud and waits to hear accept

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .open: return loc("Open")
        case .confirmOnScreen: return loc("Confirm on screen")
        case .confirmByVoice: return loc("Confirm by voice")
        }
    }

    var explanation: String {
        switch self {
        case .open:
            return loc("Agents can start listening right away. The recording indicator always shows when they do.")
        case .confirmOnScreen:
            return loc("Nothing reaches the agent until you accept on screen.")
        case .confirmByVoice:
            return loc("Aloud asks out loud and waits for you to say accept — no need to look at the screen.")
        }
    }
}
