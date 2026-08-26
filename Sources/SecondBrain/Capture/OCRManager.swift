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
                    await MainActor.run {
                        self.copyTextToClipboard(text)
                        DisplayAdvisor.hintIfNeeded(for: region.displayID)
                    }
                    Log.info("OCR copied \(text.count) chars to clipboard")
                } catch {
                    Log.error("OCR failed: \(error)")
                }
            }
        }
    }

    func recognizeText(in cgImage: CGImage) async throws -> String {
        let image = Self.upscaledForRecognition(cgImage)
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                continuation.resume(returning: Self.text(from: observations))
            }
            request.recognitionLevel = .accurate
            // Correction trades glyph fidelity for dictionary plausibility, so
            // punctuation-heavy text (code, IDs) comes out wrong. Off by default.
            request.usesLanguageCorrection = Settings.shared.ocrLanguageCorrection
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = Self.preferredLanguages(for: request)

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Vision resolves glyphs far more reliably when they are tall in pixels.
    /// A small selection — a single line of UI text, say — is only a handful of
    /// pixels high, which is where `{` starts coming back as `<`. Enlarging it
    /// smoothly first costs a millisecond and removes most of those mix-ups.
    private static func upscaledForRecognition(_ image: CGImage) -> CGImage {
        let shortest = CGFloat(min(image.width, image.height))
        guard shortest > 0 else { return image }

        let target = CGFloat(max(200, Settings.shared.ocrTargetShortestSide))
        let maxFactor = CGFloat(max(1, Settings.shared.ocrMaxUpscale))
        let factor = min(maxFactor, max(1, (target / shortest).rounded(.down)))
        guard factor > 1 else { return image }

        let width = Int(CGFloat(image.width) * factor)
        let height = Int(CGFloat(image.height) * factor)
        guard width <= 12_000, height <= 12_000,
              let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Groups observations into visual rows so multi-column captures read
    /// left-to-right instead of interleaving columns.
    private static func text(from observations: [VNRecognizedTextObservation]) -> String {
        let pieces = observations.compactMap { obs -> (rect: CGRect, string: String)? in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return (obs.boundingBox, candidate.string)
        }
        guard !pieces.isEmpty else { return "" }

        // Vision uses a bottom-left origin, so descending midY is top-down.
        let sorted = pieces.sorted { $0.rect.midY > $1.rect.midY }
        var rows: [[(rect: CGRect, string: String)]] = []
        for piece in sorted {
            let tolerance = max(piece.rect.height, 0.01) * 0.6
            if let last = rows.last, let ref = last.first,
               abs(ref.rect.midY - piece.rect.midY) <= tolerance {
                rows[rows.count - 1].append(piece)
            } else {
                rows.append([piece])
            }
        }

        return rows
            .map { row in
                row.sorted { $0.rect.minX < $1.rect.minX }
                    .map(\.string)
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
    }

    /// System languages first so mixed-language screens are handled, without
    /// hard-coding English.
    private static func preferredLanguages(for request: VNRecognizeTextRequest) -> [String] {
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let preferred = Locale.preferredLanguages.compactMap { tag -> String? in
            supported.first { $0 == tag } ?? supported.first { $0.hasPrefix(String(tag.prefix(2))) }
        }
        var seen = Set<String>()
        return preferred.filter { seen.insert($0).inserted }
    }

    @MainActor
    func copyTextToClipboard(_ text: String) {
        guard !text.isEmpty else {
            Log.info("OCR produced no text")
            HUD.shared.show("No text found", symbol: "text.viewfinder")
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        _ = VaultWriter.save(text: text)
        let chars = text.count
        if SecretGuard.looksSecret(text) {
            HUD.shared.show("Copied — not filed (looks like a secret)", symbol: "eye.slash")
        } else {
            HUD.shared.show("Copied \(chars) character\(chars == 1 ? "" : "s")", symbol: "text.viewfinder")
        }
    }
}
