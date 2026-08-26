import Foundation
import AppKit

/// Inspects the host machine and produces recommendations for the
/// transcription model size, backend, and AI execution strategy that best
/// fit the available hardware.
final class SystemProfiler {
    static let shared = SystemProfiler()
    private init() {}

    struct Profile {
        let isAppleSilicon: Bool
        let chipName: String
        let physicalCores: Int
        let memoryGB: Double
        let osVersion: String

        /// A stable signature used to detect hardware/OS changes between launches.
        var signature: String {
            "\(chipName)|\(physicalCores)|\(Int(memoryGB))|\(osVersion)"
        }
    }

    struct Recommendation {
        let whisperModel: String
        let whisperBackend: TranscriptionBackend
        let aiStrategy: String
        let summary: String
    }

    private(set) lazy var profile: Profile = buildProfile()

    func recommend() -> Recommendation {
        let p = profile
        let model: String
        // Tiron carries a large-v3-sized checkpoint and decodes twice, so it only
        // earns its keep on machines with memory and a GPU to spare.
        var backend: TranscriptionBackend = .whisperCpp

        switch (p.isAppleSilicon, p.memoryGB) {
        case (true, let mem) where mem >= 32:
            model = "large-v3"
            backend = .tiron
        case (true, let mem) where mem >= 16:
            model = "medium.en"
            backend = .tiron
        case (true, _):
            model = "small.en"
        case (false, let mem) where mem >= 16:
            model = "small.en"
        default:
            model = "base.en"
        }

        let aiStrategy: String
        if p.isAppleSilicon && p.memoryGB >= 32 {
            aiStrategy = "oMLX with an 8B–30B MLX model; Ollama optional as a fallback."
        } else if p.isAppleSilicon && p.memoryGB >= 16 {
            aiStrategy = "oMLX with Llama 3.2 3B (or similar); leaves RAM for live transcription."
        } else if p.isAppleSilicon {
            aiStrategy = "oMLX with a 1B model, or a cloud API for heavier work."
        } else {
            aiStrategy = "Prefer a cloud API — local LLM inference will be slow on this machine."
        }

        let speakers = backend.attributesSpeakers
            ? "Tiron labels who said what in the same pass"
            : "not available on \(backend.displayName) — switch to Tiron for meetings"

        let capture = DisplayAdvisor.recommendedTuning()
        let displays = capture.snapshots.isEmpty
            ? "no displays reported"
            : capture.snapshots.map(\.summary).joined(separator: "\n  ")

        let summary = """
        Detected: \(p.chipName), \(p.physicalCores) cores, \(String(format: "%.0f", p.memoryGB)) GB RAM, macOS \(p.osVersion).
        • Recording transcription: \(backend.displayName)\(backend.usesWhisperModel ? ", model \(model)" : "")
        • Speaker attribution: \(speakers)
        • Live transcription: heed (⌃⌥T)
        • Local AI: \(aiStrategy)
        • Displays:
          \(displays)
        • Capture Area: native framebuffer pixels
        • OCR: upscale up to \(capture.ocrMaxUpscale)× toward \(capture.ocrTargetShortestSide) px
        """

        return Recommendation(
            whisperModel: model,
            whisperBackend: backend,
            aiStrategy: aiStrategy,
            summary: summary
        )
    }

    /// Applies recommended defaults and notifies the user when the machine
    /// signature changes (first launch, new hardware, OS upgrade).
    func evaluateAndNotifyIfNeeded() {
        let rec = recommend()
        let sig = profile.signature
        Log.info("System profile: \(sig)")

        if Settings.shared.lastSystemSignature != sig {
            Settings.shared.lastSystemSignature = sig
            // Seed sensible defaults derived from the hardware.
            Settings.shared.whisperModel = rec.whisperModel
            Settings.shared.whisperBackend = rec.whisperBackend
            Log.info("Applied recommended settings:\n\(rec.summary)")
            presentRecommendation(rec)
        }
        // Displays are independent of chip/RAM: a first install on another Mac,
        // or plugging in a different monitor, retunes Capture Area and OCR.
        DisplayAdvisor.applyRecommendedSettingsIfNeeded()
    }

    func presentRecommendation(_ rec: Recommendation) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "\(AppInfo.name) — Recommended Setup"
            alert.informativeText = rec.summary
            alert.addButton(withTitle: "Use Recommended")
            alert.addButton(withTitle: "Keep Current")
            alert.alertStyle = .informational
            NSApp.activate(ignoringOtherApps: true)
            _ = alert.runModal()
        }
    }

    // MARK: - Hardware probing

    private func buildProfile() -> Profile {
        Profile(
            isAppleSilicon: Self.isAppleSilicon(),
            chipName: Self.sysctlString("machdep.cpu.brand_string") ?? Self.sysctlString("hw.model") ?? "Unknown",
            physicalCores: Int(Self.sysctlInt("hw.physicalcpu") ?? 0),
            memoryGB: Double(Self.sysctlInt("hw.memsize") ?? 0) / 1_073_741_824.0,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    private static func isAppleSilicon() -> Bool {
        #if arch(arm64)
        return true
        #else
        // Detect Rosetta-translated processes too.
        var ret = Int32(0)
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &ret, &size, nil, 0) == 0 {
            return ret == 1
        }
        return false
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        if sysctlbyname(name, &value, &size, nil, 0) == 0 { return value }
        // Some keys are 32-bit.
        var v32: Int32 = 0
        var size32 = MemoryLayout<Int32>.size
        if sysctlbyname(name, &v32, &size32, nil, 0) == 0 { return Int64(v32) }
        return nil
    }
}
