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
        let enableDiarization: Bool
        let aiStrategy: String
        let summary: String
    }

    private(set) lazy var profile: Profile = buildProfile()

    func recommend() -> Recommendation {
        let p = profile
        let model: String
        var diarization = false
        let backend: TranscriptionBackend = .whisperCpp

        switch (p.isAppleSilicon, p.memoryGB) {
        case (true, let mem) where mem >= 32:
            model = "large-v3"
            diarization = true
        case (true, let mem) where mem >= 16:
            model = "medium.en"
            diarization = true
        case (true, _):
            model = "small.en"
        case (false, let mem) where mem >= 16:
            model = "small.en"
        default:
            model = "base.en"
        }

        let aiStrategy: String
        if p.isAppleSilicon && p.memoryGB >= 16 {
            aiStrategy = "Run a local model (Ollama/llama.cpp) for privacy; fall back to a cloud API for heavy tasks."
        } else {
            aiStrategy = "Prefer a cloud API — local LLM inference will be slow on this machine."
        }

        let summary = """
        Detected: \(p.chipName), \(p.physicalCores) cores, \(String(format: "%.0f", p.memoryGB)) GB RAM, macOS \(p.osVersion).
        • Whisper model: \(model) (\(backend.displayName))
        • Speaker diarization: \(diarization ? "recommended" : "off (limited resources)")
        • AI: \(aiStrategy)
        """

        return Recommendation(
            whisperModel: model,
            whisperBackend: backend,
            enableDiarization: diarization,
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
            Settings.shared.enableDiarization = rec.enableDiarization
            Log.info("Applied recommended settings:\n\(rec.summary)")
            presentRecommendation(rec)
        }
    }

    func presentRecommendation(_ rec: Recommendation) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Snapture — Recommended Setup"
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
