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
