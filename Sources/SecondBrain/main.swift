import AppKit

// 2ⁿᵈ Brain — a menu-bar-only macOS capture & clipboard utility.
// Entry point. Runs as an accessory (no Dock icon, no main window).

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
