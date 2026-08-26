import AppKit

/// Detects a display running a non-HiDPI mode. macOS then renders only one
/// pixel per point, so captures and OCR from that screen are soft no matter how
/// carefully we ask for pixels — the detail was never drawn. Switching to a
/// HiDPI mode of roughly the same usable size is the only real fix, so surface
/// it once per mode instead of silently returning blurry images.
enum DisplayAdvisor {
    struct Advice {
        let currentPoints: CGSize
        let suggestedPoints: CGSize
        let suggestedPixels: CGSize

        /// How many more pixels a capture would contain after switching. Advice
        /// only exists for non-HiDPI modes, where points and pixels are equal.
        var pixelGain: Double {
            let now = currentPoints.width * currentPoints.height
            guard now > 0 else { return 1 }
            return (suggestedPixels.width * suggestedPixels.height) / now
        }
    }

    /// Nil when the display already renders at HiDPI, or when no better mode of
    /// a comparable size exists.
    static func advice(for displayID: CGDirectDisplayID) -> Advice? {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return nil }
        guard mode.pixelWidth <= mode.width else { return nil }

        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []

        // Closest in usable space, so the desktop barely changes size.
        let best = modes
            .filter { $0.pixelWidth > $0.width && $0.pixelWidth > mode.pixelWidth }
            .min { lhs, rhs in
                let l = abs(lhs.width - mode.width) + abs(lhs.height - mode.height)
                let r = abs(rhs.width - mode.width) + abs(rhs.height - mode.height)
                return l < r
            }
        guard let best else { return nil }

        return Advice(
            currentPoints: CGSize(width: mode.width, height: mode.height),
            suggestedPoints: CGSize(width: best.width, height: best.height),
            suggestedPixels: CGSize(width: best.pixelWidth, height: best.pixelHeight)
        )
    }

    /// Shows the hint at most once per display mode; the user can silence it.
    @MainActor
    static func hintIfNeeded(for displayID: CGDirectDisplayID) {
        guard let advice = advice(for: displayID) else { return }

        let signature = "\(displayID)|\(Int(advice.currentPoints.width))x\(Int(advice.currentPoints.height))"
        guard Settings.shared.dismissedDisplayHint != signature else { return }
        Settings.shared.dismissedDisplayHint = signature

        Log.info("Display \(displayID) is non-HiDPI at \(signature); suggesting a Retina mode")

        let alert = NSAlert()
        alert.messageText = "This display is not running in Retina mode"
        alert.informativeText = """
        macOS is drawing your screen at \(Int(advice.currentPoints.width))×\(Int(advice.currentPoints.height)) \
        actual pixels, so that is all a screenshot can contain and it is why captures and OCR look soft.

        In System Settings → Displays, choosing the scaled resolution that looks like \
        \(Int(advice.suggestedPoints.width))×\(Int(advice.suggestedPoints.height)) keeps about the same amount of \
        room on screen but renders \(Int(advice.suggestedPixels.width))×\(Int(advice.suggestedPixels.height)) pixels — \
        roughly \(String(format: "%.1f", advice.pixelGain))× the detail in every capture.
        """
        alert.addButton(withTitle: "Open Display Settings")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")
            if let url { NSWorkspace.shared.open(url) }
        }
    }
}
