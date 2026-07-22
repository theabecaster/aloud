import AVFoundation
import AppKit
import ApplicationServices

// Central permission checks + System Settings deep links. See docs/permissions.md.
enum Permissions {
    enum Status: String { case granted, denied, notDetermined }

    // MARK: Microphone

    static var microphone: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async { completion(ok) }
        }
    }

    // MARK: Accessibility (event tap + synthetic paste)

    static var accessibility: Status {
        AXIsProcessTrusted() ? .granted : .denied
    }

    // Shows the system's own "grant accessibility" prompt (once per app path).
    static func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: Deep links

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    static var allGranted: Bool { microphone == .granted && accessibility == .granted }
}
