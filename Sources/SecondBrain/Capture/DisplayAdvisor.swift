import AppKit

/// Inspects connected displays so Capture Area and OCR can be tuned to the
/// pixels that actually exist, and so a first install on a different Mac does
/// not inherit the previous machine's Retina assumptions.
enum DisplayAdvisor {
    struct Advice: Sendable {
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

    /// One connected screen, measured in both points and framebuffer pixels.
    struct Snapshot: Identifiable, Sendable {
        let id: CGDirectDisplayID
        let name: String
        let points: CGSize
        let pixels: CGSize
        let scale: CGFloat
        let advice: Advice?

        var isHiDPI: Bool { scale > 1.01 }

        var summary: String {
            let mode = isHiDPI
                ? "Retina \(String(format: "%.0f", scale))×"
                : "1× (non-Retina)"
            return "\(name): \(Int(points.width))×\(Int(points.height)) pt · \(Int(pixels.width))×\(Int(pixels.height)) px · \(mode)"
        }
    }

    /// OCR and capture knobs derived from the weakest (lowest-scale) display,
    /// because that is the one that will otherwise produce soft glyphs.
    struct CaptureTuning: Sendable {
        let ocrTargetShortestSide: Int
        let ocrMaxUpscale: Int
        let minScale: CGFloat
        let snapshots: [Snapshot]

        var blurb: String {
            "Capture Area uses native framebuffer pixels (\(String(format: "%.0f", minScale))×). OCR enlarges selections up to \(ocrMaxUpscale)× toward \(ocrTargetShortestSide) px so glyphs stay readable on this density."
        }
    }

    /// Point-to-pixel scale of the framebuffer, not `backingScaleFactor`. The
    /// latter reported 1× here on a Retina panel running a non-HiDPI mode, which
    /// made the selection overlay snap to the wrong grid.
    static func pixelScale(of displayID: CGDirectDisplayID, screen: NSScreen? = nil) -> CGFloat {
        let fallback = max(1, screen?.backingScaleFactor ?? 1)
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0, mode.pixelWidth > 0 else {
            return fallback
        }
        let fromMode = CGFloat(mode.pixelWidth) / CGFloat(mode.width)
        return max(fromMode, fallback)
    }

    static func snapshots() -> [Snapshot] {
        NSScreen.screens.map { screen in
            let id = screen.displayID
            let points = screen.frame.size
            let scale = pixelScale(of: id, screen: screen)
            let pixels: CGSize
            if let mode = CGDisplayCopyDisplayMode(id), mode.pixelWidth > 0 {
                pixels = CGSize(width: CGFloat(mode.pixelWidth), height: CGFloat(mode.pixelHeight))
            } else {
                pixels = CGSize(width: points.width * scale, height: points.height * scale)
            }
            return Snapshot(
                id: id,
                name: screen.localizedName,
                points: points,
                pixels: pixels,
                scale: scale,
                advice: advice(for: id)
            )
        }
    }

    /// Stable enough to notice a new Mac, a new monitor, or a resolution change.
    static func displaySignature() -> String {
        snapshots()
            .map { "\($0.id):\($0.pixels.width)x\($0.pixels.height)@\(String(format: "%.2f", $0.scale))" }
            .sorted()
            .joined(separator: ",")
    }

    static func recommendedTuning(from snapshots: [Snapshot]? = nil) -> CaptureTuning {
        let snaps = snapshots ?? Self.snapshots()
        let minScale = snaps.map(\.scale).min() ?? 2
        // Vision wants glyphs tens of pixels tall. A 1× UI label is ~11 px; a
        // 2× one is already ~22. Cap the upscale so a full-screen grab does not
        // balloon past a few thousand pixels on a side.
        let target: Int
        let maxUpscale: Int
        switch minScale {
        case ..<1.5:
            target = 1200
            maxUpscale = 8
        case 1.5..<2.5:
            target = 800
            maxUpscale = 4
        default:
            target = 600
            maxUpscale = 3
        }
        return CaptureTuning(
            ocrTargetShortestSide: target,
            ocrMaxUpscale: maxUpscale,
            minScale: minScale,
            snapshots: snaps
        )
    }

    /// First install, a different Mac, or a display change: rewrite OCR and
    /// Capture Area settings from the screens that are actually attached.
    static func applyRecommendedSettingsIfNeeded() {
        let signature = displaySignature()
        guard Settings.shared.lastDisplaySignature != signature else { return }

        let tuning = recommendedTuning()
        Settings.shared.lastDisplaySignature = signature
        Settings.shared.ocrTargetShortestSide = tuning.ocrTargetShortestSide
        Settings.shared.ocrMaxUpscale = tuning.ocrMaxUpscale
        Log.info("Display tuning applied:\n\(tuning.blurb)")
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
