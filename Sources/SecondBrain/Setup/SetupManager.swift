import Foundation

/// Owns the one-time job of making this Mac able to run every engine locally.
///
/// The actual work lives in `scripts/bootstrap.sh` (shipped inside the app
/// bundle) because it is all package management; this class runs it, parses its
/// `STEP|` progress lines, and exposes them for the setup window and the menu.
@MainActor
final class SetupManager: ObservableObject {
    static let shared = SetupManager()

    enum Phase: Equatable {
        case idle          // not looked yet
        case checking      // probing what's installed
        case installing
        case done
    }

    enum StepState: Equatable {
        case unknown
        case checking
        case installing
        case ready
        case missing(String)
        case needsYou(String)  // requires a password or a system dialog
        case skipped(String)
    }

    struct Step: Identifiable {
        let id: String
        let title: String
        let purpose: String
        var state: StepState = .unknown

        var isSatisfied: Bool {
            switch state {
            case .ready, .skipped: return true
            default: return false
            }
        }
    }

    @Published private(set) var steps: [Step] = Step.everything
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var log: String = ""
    @Published private(set) var summary: String = ""
    /// A local LLM is optional: everything else is required for the core features.
    @Published var includeLocalAI = true

    private var process: Process?
    private var pending = ""
    private var hasProbed = false

    private init() {}

    // MARK: - Status

    /// True until a bootstrap run has finished successfully at least once.
    var hasRunSetup: Bool { Settings.shared.setupCompletedVersion != nil }

    var isBusy: Bool { phase == .checking || phase == .installing }

    /// Everything the core features need. When Local AI is on, Ollama must be
    /// *ready* (not merely skipped).
    var isReady: Bool {
        guard hasProbed else { return false }
        return steps.allSatisfy { !isBlockingUnsatisfied($0) }
    }

    /// Nil until a run has actually reported back, so nothing claims an engine is
    /// missing before we've looked.
    var missingCount: Int? {
        guard hasProbed else { return nil }
        return steps.filter(isBlockingUnsatisfied).count
    }

    private var optionalIDs: Set<String> {
        var ids = Step.optionalIDs
        if includeLocalAI { ids.remove(Step.ollamaID) }
        return ids
    }

    private func isBlockingUnsatisfied(_ step: Step) -> Bool {
        if optionalIDs.contains(step.id) { return false }
        if step.id == Step.ollamaID, includeLocalAI {
            if case .ready = step.state { return false }
            return true
        }
        return !step.isSatisfied
    }

    func state(of id: String) -> StepState {
        steps.first { $0.id == id }?.state ?? .unknown
    }

    // MARK: - Running

    /// Reports what is already installed without touching anything.
    func check() async {
        guard !isBusy else { return }
        var arguments = ["--check"]
        if includeLocalAI { arguments.append("--with-ollama") }
        await run(arguments: arguments, phase: .checking)
    }

    /// Installs everything that's missing. Long — Tiron and heed download GBs.
    func installMissing() async {
        guard !isBusy else { return }
        var arguments = ["--model", Settings.shared.whisperModel]
        if includeLocalAI { arguments.append("--with-ollama") }
        await run(arguments: arguments, phase: .installing)

        if isReady {
            Settings.shared.setupCompletedVersion = AppInfo.version
            // Models are on disk — start heed now so the first ⌃⌥T doesn't wait.
            Task { try? await HeedSupervisor.shared.ensureRunning { _ in } }
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
        if phase == .installing { summary = "Setup cancelled — you can pick up where it left off." }
        phase = .done
    }

    private func run(arguments: [String], phase newPhase: Phase) async {
        guard let script = Self.bootstrapScript else {
            summary = "Setup script is missing from the app bundle."
            phase = .done
            return
        }

        phase = newPhase
        summary = ""
        pending = ""
        if newPhase == .installing {
            if log.isEmpty {
                log = "Installing only what is missing. Already-finished engines stay on disk; downloads resume after a drop.\n"
            } else {
                log += "\n— Resuming: skipping what is already installed —\n"
            }
        }
        for index in steps.indices {
            let step = steps[index]
            if step.id == Step.ollamaID, includeLocalAI, case .skipped = step.state {
                steps[index].state = .unknown
                continue
            }
            if steps[index].isSatisfied { continue }
            steps[index].state = .unknown
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        // A GUI app launched from Finder inherits almost no PATH, and every tool
        // we shell out to lives in one of these.
        var environment = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                     NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.bun/bin"]
        environment["PATH"] = (extra + [environment["PATH"] ?? ""]).joined(separator: ":")
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in SetupManager.shared.ingest(chunk) }
        }

        self.process = process
        // The handler has to be in place before the process can exit, or a fast
        // run finishes before we start listening and we wait forever.
        var launchError: Error?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                launchError = error
                process.terminationHandler = nil
                continuation.resume()
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil

        if let launchError {
            summary = "Could not start setup: \(launchError.localizedDescription)"
            self.process = nil
            phase = .done
            return
        }
        // Anything buffered without a trailing newline.
        if !pending.isEmpty { ingest("\n") }
        self.process = nil
        phase = .done
        Log.info("Setup \(newPhase == .checking ? "check" : "install") finished: \(summary)")
    }

    // MARK: - Progress parsing

    private func ingest(_ chunk: String) {
        pending += chunk
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[pending.startIndex..<newline])
            pending = String(pending[pending.index(after: newline)...])
            handle(line: line)
        }
        // Keep the log from growing without bound during a long install.
        if log.count > 200_000 { log = String(log.suffix(150_000)) }
    }

    private func handle(line: String) {
        let parts = line.components(separatedBy: "|")
        switch parts.first {
        case "STEP" where parts.count >= 4:
            apply(state: parts[2], message: parts[3], to: parts[1])
            log += "• \(parts[3])\n"
        case "DONE" where parts.count >= 3:
            summary = parts[2]
            hasProbed = true
        default:
            log += line + "\n"
        }
    }

    private func apply(state: String, message: String, to id: String) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        switch state {
        case "checking":   steps[index].state = .checking
        case "installing": steps[index].state = .installing
        case "ok":         steps[index].state = .ready
        case "failed":     steps[index].state = .missing(message)
        case "manual":     steps[index].state = .needsYou(message)
        case "skipped":    steps[index].state = .skipped(message)
        default:           break
        }
    }

    // MARK: - Script location

    /// Bundled in the installed app; falls back to the repo copy for dev builds.
    private static var bootstrapScript: URL? {
        if let bundled = Bundle.main.url(forResource: "bootstrap", withExtension: "sh") {
            return bundled
        }
        let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/bootstrap.sh")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }
}

extension SetupManager.Step {
    static let ollamaID = "ollama"
    static let screenpipeID = "screenpipe"

    /// Steps that never block “ready” — nice-to-have extras.
    /// Steps that never block “ready” — nice-to-have extras.
    /// `defend` asks for an admin password; declining it still leaves skills + logs.
    static let optionalIDs: Set<String> = [ollamaID, screenpipeID, "defend"]

    /// Order matches the bootstrap script, so progress reads top to bottom.
    static let everything: [SetupManager.Step] = [
        .init(id: "requirements", title: "This Mac",
              purpose: "macOS version, chip, memory and free space"),
        .init(id: "brew", title: "Homebrew",
              purpose: "Fetches the local engines"),
        .init(id: "node", title: "Node",
              purpose: "Runs heed's installer"),
        .init(id: "bun", title: "Bun",
              purpose: "Runs the live-transcription server"),
        .init(id: "python", title: "Python 3.12",
              purpose: "Runtime for heed, Tiron, and oMLX Interpreter"),
        .init(id: "ffmpeg", title: "ffmpeg",
              purpose: "Audio conversion"),
        .init(id: "whisper", title: "whisper.cpp + model",
              purpose: "Fast transcription of your own recordings"),
        .init(id: "tiron", title: "Tiron + model",
              purpose: "Who-said-what for meetings (about 3 GB)"),
        .init(id: "heed", title: "heed + Neural Engine models",
              purpose: "Live transcription with speakers as you speak"),
        .init(id: "omlx", title: "oMLX",
              purpose: "Local LLM inference server for Apple Silicon"),
        .init(id: "omlx_interpreter", title: "oMLX Interpreter",
              purpose: "Local coding agent that talks to oMLX"),
        .init(id: "vscode", title: "VS Code + Cline + Roo + Kilo",
              purpose: "AI agents + Cline CLI (overnight) + oMLX/OpenRouter; opens ~/Desktop/2nd Brain in VS Code"),
        .init(id: "agent_skills", title: "Agent skills + MCP registry",
              purpose: "Next.js, NestJS, n8n, OpenRouter model selection & thinking skills on Desktop"),
        .init(id: screenpipeID, title: "Screenpipe (optional)",
              purpose: "Always-on local screen + audio memory"),
        .init(id: "tts", title: "Local TTS",
              purpose: "Piper neural voices (falls back to macOS say)"),
        .init(id: "brain", title: "Knowledge vault + engraph",
              purpose: "Markdown second brain with graph search MCP"),
        .init(id: "obsidian", title: "Obsidian + vault plugins",
              purpose: "Graph view over the vault: calendar, tasks, search, local AI, dashboards"),
        .init(id: "caldav", title: "Local CalDAV calendar",
              purpose: "Radicale on 127.0.0.1 — Apple Calendar, vault task sync, no Google"),
        .init(id: "defend", title: "Sandbox user + network guard",
              purpose: "Prod + dev overnight users, activity watch, Little Snitch 3h filter keeper"),
        .init(id: ollamaID, title: "Ollama",
              purpose: "Qwen 3.5 4B (notes) + Qwen 2.5 Coder 7B (code) on this Mac")
    ]
}
