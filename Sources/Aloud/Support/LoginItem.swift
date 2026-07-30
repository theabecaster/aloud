import Foundation
import ServiceManagement

// Launch-at-login via SMAppService (macOS 13+). Only meaningful when running
// from a real .app bundle; a dev binary reports unsupported.
enum LoginItem {
    static var isSupported: Bool {
        Bundle.main.bundleURL.path.hasSuffix(".app")
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // For --doctor: macOS's own verdict, including the two states that make
    // the switch look broken — `requiresApproval` (the user denied it in
    // System Settings → Login Items) and `notFound`.
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard isSupported else { return false }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }
}
