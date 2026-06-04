import AVFoundation
import AppKit
import CoreGraphics
import ApplicationServices

/// Centralised permission checks. Screen Recording permission is required for
/// screenshots, OCR-of-screen, and screen recording. Microphone permission is
/// required for mic capture. Accessibility is required only for auto-paste.
enum Permissions {
    static func hasScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    static func microphoneStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// Opens the relevant System Settings privacy pane.
    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Accessibility (only needed for auto-paste)

    /// Checks Accessibility trust WITHOUT showing the system prompt.
    static func hasAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    /// Explicitly asks for Accessibility (shows the system prompt). Call this
    /// only from a user-initiated action, never implicitly.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Relaunches the app. Screen Recording permission only takes effect after a
    /// restart, so we offer this once the user has granted it in System Settings.
    static func relaunchApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Standardised "needs Screen Recording" flow: request access (shows the
    /// system dialog the first time), open Settings, and offer to relaunch.
    static func guideScreenRecording() {
        requestScreenRecording()
        let alert = NSAlert()
        alert.messageText = "Enable Screen Recording for Snapture"
        alert.informativeText = """
        1. In System Settings → Privacy & Security → Screen Recording, turn ON Snapture.
        2. Come back here and click “Quit & Reopen” — the permission only applies after a restart.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Quit & Reopen")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: openScreenRecordingSettings()
        case .alertSecondButtonReturn: relaunchApp()
        default: break
        }
    }
}
