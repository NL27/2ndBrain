import AppKit
import Vision

/// Runs on-device OCR (Vision framework) over a selected screen region and
/// copies the recognized text to the clipboard.
final class OCRManager {
    static let shared = OCRManager()
    private init() {}

    func captureRegionAndCopyText() {
        SelectionOverlay.shared.begin { region in
            guard let region else { return }
            Task {
                do {
                    let cgImage = try await ScreenshotManager.shared.capture(region: region)
                    let text = try await self.recognizeText(in: cgImage)
                    await MainActor.run { self.copyTextToClipboard(text) }
                    Log.info("OCR copied \(text.count) chars to clipboard")
                } catch {
                    Log.error("OCR failed: \(error)")
                }
            }
        }
    }

    func recognizeText(in cgImage: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // Use all available languages the system supports.
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    @MainActor
    func copyTextToClipboard(_ text: String) {
        guard !text.isEmpty else {
            Log.info("OCR produced no text")
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
