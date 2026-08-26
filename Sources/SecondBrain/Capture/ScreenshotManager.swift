import AppKit
import CoreVideo
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Captures screen regions to a CGImage using ScreenCaptureKit and places the
/// result on the clipboard.
final class ScreenshotManager {
    static let shared = ScreenshotManager()
    private init() {}

    enum CaptureError: Error { case displayNotFound, noPermission, cropFailed }

    /// Entry point used by the menu / hotkey: shows the selection overlay and
    /// copies the captured image to the clipboard.
    func captureRegionToClipboard() {
        guard ensurePermission() else { return }
        SelectionOverlay.shared.begin { region in
            guard let region else { return }
            Task {
                do {
                    let image = try await ScreenshotManager.shared.capture(region: region)
                    await MainActor.run {
                        ScreenshotManager.shared.copyImageToClipboard(image, pointSize: region.rectInPoints.size)
                        DisplayAdvisor.hintIfNeeded(for: region.displayID)
                    }
                    Log.info("Screenshot copied to clipboard (\(image.width)x\(image.height))")
                } catch {
                    Log.error("Screenshot capture failed: \(error)")
                }
            }
        }
    }

    /// Captures a region and returns the CGImage (used by OCR as well).
    func capture(region: CaptureRegion) async throws -> CGImage {
        // The overlay has just been ordered out; give the window server a frame
        // so we don't snapshot the dimmed selection UI.
        try await Task.sleep(nanoseconds: 50_000_000)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == region.displayID })
                ?? content.displays.first else {
            throw CaptureError.displayNotFound
        }

        let excluded = content.windows.filter { region.excludedWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        // Ask for the display's true framebuffer size: every pixel that exists,
        // and no upscaling beyond it. SCContentFilter's own contentRect and
        // pointPixelScale reported 1x here and cost us half the pixels on
        // Retina modes, so measure the display directly instead.
        let pointSize = region.screen.frame.size
        let pixelSize = Self.framebufferSize(of: region)

        let config = SCStreamConfiguration()
        config.width = max(1, Int(pixelSize.width.rounded()))
        config.height = max(1, Int(pixelSize.height.rounded()))
        config.showsCursor = false
        config.scalesToFit = false
        config.captureResolution = .best
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB

        let full = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        Log.debug("""
        Capture: \(Int(pointSize.width))x\(Int(pointSize.height))pt \
        framebuffer \(Int(pixelSize.width))x\(Int(pixelSize.height))px \
        -> got \(full.width)x\(full.height)px
        """)
        return try crop(full, to: region.rectInPoints, displayPointSize: pointSize)
    }

    /// Real pixel dimensions the window server renders this display at. In a
    /// Retina mode the display mode reports double its point size; in a
    /// non-HiDPI mode the two are equal and there is genuinely nothing more to
    /// capture. `backingScaleFactor` is the fallback when the mode is unknown.
    private static func framebufferSize(of region: CaptureRegion) -> CGSize {
        let points = region.screen.frame.size
        let fallback = CGSize(width: points.width * max(1, region.scale),
                              height: points.height * max(1, region.scale))
        guard let mode = CGDisplayCopyDisplayMode(region.displayID) else { return fallback }
        let modePixels = CGSize(width: CGFloat(mode.pixelWidth), height: CGFloat(mode.pixelHeight))
        guard modePixels.width > 0, modePixels.height > 0 else { return fallback }
        return CGSize(width: max(modePixels.width, fallback.width),
                      height: max(modePixels.height, fallback.height))
    }

    /// Pixel-exact crop. Maps the point-space selection through the scale the
    /// capture actually came back at, so a clamped request still crops right.
    private func crop(_ image: CGImage, to rectInPoints: CGRect, displayPointSize: CGSize) throws -> CGImage {
        let scaleX = displayPointSize.width > 0 ? CGFloat(image.width) / displayPointSize.width : 1
        let scaleY = displayPointSize.height > 0 ? CGFloat(image.height) / displayPointSize.height : 1

        let x0 = (rectInPoints.minX * scaleX).rounded()
        let y0 = (rectInPoints.minY * scaleY).rounded()
        let x1 = (rectInPoints.maxX * scaleX).rounded()
        let y1 = (rectInPoints.maxY * scaleY).rounded()

        let pixelRect = CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = pixelRect.intersection(bounds).integral
        guard !clamped.isNull, !clamped.isEmpty,
              let cropped = image.cropping(to: clamped) else {
            throw CaptureError.cropFailed
        }
        return cropped
    }

    @MainActor
    func copyImageToClipboard(_ cgImage: CGImage, pointSize: NSSize) {
        let nsImage = Self.makeNSImage(from: cgImage, pointSize: pointSize)
        let png = Self.pngData(from: cgImage, pointSize: pointSize)
        let pb = NSPasteboard.general
        pb.clearContents()
        // Bitmap types only. NSImage.writeObjects also publishes a PDF
        // representation that many apps prefer and then rasterize at 72 DPI —
        // which is what made area screenshots look unsharp when pasted.
        var types: [NSPasteboard.PasteboardType] = [.tiff]
        if png != nil { types.append(.png) }
        pb.declareTypes(types, owner: nil)
        if let png { pb.setData(png, forType: .png) }
        if let tiff = nsImage.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
        ClipboardManager.shared.noteInternalImageCopy(nsImage, png: png)
        HUD.shared.show("Screenshot copied", symbol: "camera.viewfinder", thumbnail: nsImage)
    }

    /// Point-sized NSImage wrapping the full-resolution bitmap (correct Retina DPI).
    static func makeNSImage(from cgImage: CGImage, pointSize: NSSize) -> NSImage {
        let size = NSSize(
            width: pointSize.width > 0 ? pointSize.width : CGFloat(cgImage.width),
            height: pointSize.height > 0 ? pointSize.height : CGFloat(cgImage.height)
        )
        let image = NSImage(size: size)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = size
        image.addRepresentation(rep)
        return image
    }

    static func pngData(from cgImage: CGImage, pointSize: NSSize) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }

        let scaleX = pointSize.width > 0 ? CGFloat(cgImage.width) / pointSize.width : 1
        let dpi = 72 * scaleX
        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private func ensurePermission() -> Bool {
        if Permissions.hasScreenRecording() { return true }
        Permissions.guideScreenRecording()
        return false
    }
}
