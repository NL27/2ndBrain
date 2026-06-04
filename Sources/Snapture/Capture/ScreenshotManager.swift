import AppKit
import ScreenCaptureKit

/// Captures screen regions to a CGImage using ScreenCaptureKit and places the
/// result on the clipboard.
final class ScreenshotManager {
    static let shared = ScreenshotManager()
    private init() {}

    enum CaptureError: Error { case displayNotFound, noPermission }

    /// Entry point used by the menu / hotkey: shows the selection overlay and
    /// copies the captured image to the clipboard.
    func captureRegionToClipboard() {
        guard ensurePermission() else { return }
        SelectionOverlay.shared.begin { region in
            guard let region else { return }
            Task {
                do {
                    let image = try await ScreenshotManager.shared.capture(region: region)
                    await MainActor.run { ScreenshotManager.shared.copyImageToClipboard(image) }
                    Log.info("Screenshot copied to clipboard (\(image.width)x\(image.height))")
                } catch {
                    Log.error("Screenshot capture failed: \(error)")
                }
            }
        }
    }

    /// Captures a region and returns the CGImage (used by OCR as well).
    func capture(region: CaptureRegion) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == region.displayID })
                ?? content.displays.first else {
            throw CaptureError.displayNotFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = region.rectInPoints
        config.width = Int(region.rectInPoints.width * region.scale)
        config.height = Int(region.rectInPoints.height * region.scale)
        config.showsCursor = false
        config.captureResolution = .best

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    @MainActor
    func copyImageToClipboard(_ cgImage: CGImage) {
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([nsImage])
        // Mark this as an internally-produced copy so the clipboard manager can
        // store it with rich metadata.
        ClipboardManager.shared.noteInternalImageCopy(nsImage)
    }

    private func ensurePermission() -> Bool {
        if Permissions.hasScreenRecording() { return true }
        Permissions.guideScreenRecording()
        return false
    }
}
