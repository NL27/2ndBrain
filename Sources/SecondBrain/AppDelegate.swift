import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("\(AppInfo.name) launching (v\(AppInfo.version))")

        // Start clipboard history monitoring immediately.
        ClipboardManager.shared.start()

        // Build the menu bar UI.
        menuBar = MenuBarController()

        // Run a system profile and surface recommendations on first launch
        // or whenever the hardware/OS footprint changes.
        SystemProfiler.shared.evaluateAndNotifyIfNeeded()

        // On the very first launch, download every local engine and model up front.
        // Afterwards just refresh status and warm-start heed so live transcription
        // is ready the moment ⌃⌥T is pressed.
        if SetupManager.shared.hasRunSetup {
            Task {
                await SetupManager.shared.check()
                if SetupManager.shared.isReady {
                    try? await HeedSupervisor.shared.ensureRunning { _ in }
                } else {
                    // Something went missing since last time — reopen setup.
                    SetupWindowController.shared.present()
                }
            }
        } else {
            SetupWindowController.shared.present()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardManager.shared.stop()
        // Don't leave the live-transcription server running once we're gone.
        HeedSupervisor.shared.stop()
        Log.info("\(AppInfo.name) terminating")
    }

    // Keep running even though there are no visible windows.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

enum AppInfo {
    /// Shown in menus, alerts, and the menu bar accessibility label.
    /// "nd" uses Unicode superscripts so it reads like a trademark-style mark.
    static let name = "2ⁿᵈ Brain"
    /// Finder / Applications folder name (ASCII; spaces are fine on macOS).
    static let appFileName = "2nd Brain"
    /// On-disk Application Support folder (no Unicode superscripts).
    static let supportFolderName = "SecondBrain"
    static let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.dao.secondbrain"

    /// Application support directory for runtime data (recordings, db, models).
    static var supportDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(supportFolderName, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            // Prefer the most recent former name first.
            for legacyName in ["CaptureKit", "Snapture"] {
                let legacy = base.appendingPathComponent(legacyName, isDirectory: true)
                if fm.fileExists(atPath: legacy.path) {
                    try? fm.moveItem(at: legacy, to: dir)
                    break
                }
            }
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
