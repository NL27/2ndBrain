import Foundation

/// Snapshot of this Mac shown in the first-launch setup window: hardware,
/// Python, and which local AI models are already on disk vs recommended.
struct MachineReport: Sendable {
    struct AIModel: Identifiable, Sendable {
        let id: String
        let name: String
        let source: String   // "Ollama", "oMLX", …
        let installed: Bool
        let recommended: Bool
    }

    let chipName: String
    let isAppleSilicon: Bool
    let physicalCores: Int
    let memoryGB: Double
    let freeDiskGB: Double
    let osVersion: String
    let pythonVersion: String?
    let pythonPath: String?
    let displays: [DisplayAdvisor.Snapshot]
    let captureTuningBlurb: String
    let models: [AIModel]
    let recommendedModelID: String
    let recommendationBlurb: String

    static func gather() -> MachineReport {
        let profile = SystemProfiler.shared.profile
        let free = freeDiskGigabytes()
        let (pyVersion, pyPath) = detectPython()
        let recommended = recommendedAIModel(memoryGB: profile.memoryGB, appleSilicon: profile.isAppleSilicon)
        let installed = installedAIModels()
        let models = mergeModels(installed: installed, recommendedID: recommended.id)
        let capture = Self.captureTuning()

        let blurb: String
        if profile.isAppleSilicon {
            blurb = """
            Pinned local models: qwen3.5:4b (notes) and qwen2.5-coder:7b (code) via Ollama. \
            Turn Local AI on and Install missing if they are not listed as installed.
            """
        } else {
            blurb = "This Mac isn't Apple Silicon — prefer smaller cloud or CPU models; oMLX needs an M-series chip."
        }

        return MachineReport(
            chipName: profile.chipName,
            isAppleSilicon: profile.isAppleSilicon,
            physicalCores: profile.physicalCores,
            memoryGB: profile.memoryGB,
            freeDiskGB: free,
            osVersion: profile.osVersion,
            pythonVersion: pyVersion,
            pythonPath: pyPath,
            displays: capture.snapshots,
            captureTuningBlurb: capture.blurb,
            models: models,
            recommendedModelID: recommended.id,
            recommendationBlurb: blurb
        )
    }

    // MARK: - Probes

    /// NSScreen is main-thread only; first-launch setup gathers the rest of this
    /// report off the main thread so Python / model probes don't freeze the window.
    private static func captureTuning() -> DisplayAdvisor.CaptureTuning {
        if Thread.isMainThread {
            return DisplayAdvisor.recommendedTuning()
        }
        return DispatchQueue.main.sync { DisplayAdvisor.recommendedTuning() }
    }

    private static func freeDiskGigabytes() -> Double {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else {
            return 0
        }
        return Double(bytes) / 1_073_741_824.0
    }

    private static func detectPython() -> (String?, String?) {
        let candidates = [
            "/opt/homebrew/bin/python3.12",
            "/usr/local/bin/python3.12",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        for path in candidates {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try? process.run()
            process.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let out, !out.isEmpty { return (out, path) }
        }
        return (nil, nil)
    }

    private struct Candidate {
        let id: String
        let name: String
        let source: String
    }

    private static let pinnedOllama: [Candidate] = [
        Candidate(id: "ollama:qwen3.5:4b", name: "qwen3.5:4b", source: "Ollama"),
        Candidate(id: "ollama:qwen2.5-coder:7b", name: "qwen2.5-coder:7b", source: "Ollama"),
    ]

    private static func recommendedAIModel(memoryGB: Double, appleSilicon: Bool) -> Candidate {
        guard appleSilicon else {
            return Candidate(id: "cloud", name: "Cloud API (local LLMs too slow here)", source: "Cloud")
        }
        return pinnedOllama[0]
    }

    private static func installedAIModels() -> [Candidate] {
        var found: [Candidate] = []

        // Ollama
        if let ollama = runCapture("/usr/bin/env", ["ollama", "list"]), !ollama.isEmpty {
            for line in ollama.split(separator: "\n").dropFirst() {
                let name = line.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                guard !name.isEmpty, name != "NAME" else { continue }
                var id = "ollama:\(name)"
                for pin in pinnedOllama where name == pin.name || name.hasPrefix(pin.name + ":") {
                    id = pin.id
                }
                found.append(Candidate(id: id, name: name, source: "Ollama"))
            }
        }

        // oMLX model dirs
        let home = FileManager.default.homeDirectoryForCurrentUser
        for modelsRoot in [
            home.appendingPathComponent(".omlx/models"),
            home.appendingPathComponent(".mlx/models"),
            home.appendingPathComponent("mlx-models")
        ] {
            guard let kids = try? FileManager.default.contentsOfDirectory(
                at: modelsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for kid in kids where (try? kid.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                found.append(Candidate(id: "omlx:\(kid.lastPathComponent)",
                                       name: kid.lastPathComponent, source: "oMLX"))
            }
        }

        return found
    }

    private static func mergeModels(installed: [Candidate], recommendedID: String) -> [AIModel] {
        var byID: [String: AIModel] = [:]
        for c in installed {
            byID[c.id] = AIModel(id: c.id, name: c.name, source: c.source,
                                 installed: true, recommended: c.id == recommendedID)
        }
        // Always show the two pinned Ollama models, even before they are pulled.
        for pin in pinnedOllama {
            if byID[pin.id] == nil {
                byID[pin.id] = AIModel(id: pin.id, name: pin.name, source: pin.source,
                                       installed: false, recommended: pin.id == recommendedID)
            }
        }
        // Always surface the recommendation even if it isn't downloaded yet.
        if byID[recommendedID] == nil {
            let rec = recommendedAIModel(
                memoryGB: SystemProfiler.shared.profile.memoryGB,
                appleSilicon: SystemProfiler.shared.profile.isAppleSilicon
            )
            byID[recommendedID] = AIModel(id: rec.id, name: rec.name, source: rec.source,
                                          installed: false, recommended: true)
        }
        return byID.values.sorted { lhs, rhs in
            if lhs.recommended != rhs.recommended { return lhs.recommended }
            if lhs.installed != rhs.installed { return lhs.installed }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func runCapture(_ exe: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin",
                       NSHomeDirectory() + "/.local/bin",
                       env["PATH"] ?? ""].joined(separator: ":")
        process.environment = env
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}
