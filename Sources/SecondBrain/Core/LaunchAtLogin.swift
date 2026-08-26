import Foundation
import ServiceManagement

/// Registers the app as a login item so it starts automatically after the user
/// logs in. macOS owns this state (System Settings ▸ General ▸ Login Items), so
/// the service status is the source of truth rather than a stored preference.
enum LaunchAtLogin {
    private static var service: SMAppService { .mainApp }

    static var status: SMAppService.Status { service.status }

    /// Registered — possibly still awaiting the user's approval.
    static var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    /// Registered, but switched off by the user in System Settings; only they
    /// can turn it back on there.
    static var needsApproval: Bool { status == .requiresApproval }

    /// Throws when macOS refuses the request — most commonly because the app is
    /// running as a bare binary instead of an installed .app bundle.
    static func setEnabled(_ enabled: Bool) throws {
        guard enabled != isEnabled else { return }
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
        Log.info("Launch at login \(enabled ? "enabled" : "disabled")")
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
