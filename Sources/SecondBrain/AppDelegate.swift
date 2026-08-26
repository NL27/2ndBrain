import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Snapture launching (v\(AppInfo.version))")

        // Start clipboard history monitoring immediately.
        ClipboardManager.shared.start()

        // Build the menu bar UI.
        menuBar = MenuBarController()

        // Run a system profile and surface recommendations on first launch
        // or whenever the hardware/OS footprint changes.
        SystemProfiler.shared.evaluateAndNotifyIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardManager.shared.stop()
        Log.info("Snapture terminating")
    }

    // Keep running even though there are no visible windows.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

enum AppInfo {
    static let name = "Snapture"
    static let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.dao.snapture"

    /// Application support directory for runtime data (recordings, db, models).
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Snapture", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
