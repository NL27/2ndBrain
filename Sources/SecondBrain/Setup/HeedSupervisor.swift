import Foundation

/// Starts and stops the local heed server on 2ⁿᵈ Brain's behalf.
///
/// heed is a local service, not a library, so live transcription needs it
/// running. Setup installs it into our support directory; from then on this
/// class launches it on demand instead of asking the user to run anything.
@MainActor
final class HeedSupervisor {
    static let shared = HeedSupervisor()
    private init() {}

    enum Failure: LocalizedError {
        case notInstalled
        case noBun
        case didNotStart(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "heed isn't installed yet."
            case .noBun:
                return "heed's runtime (Bun) is missing — open Setup to install it."
            case .didNotStart(let detail):
                return "heed didn't finish starting: \(detail)"
            }
        }
    }

    private var process: Process?

    /// Where setup puts heed, plus the places `create-heed` uses when run by hand.
    var installDirectory: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            AppInfo.supportDirectory.appendingPathComponent("heed", isDirectory: true),
            home.appendingPathComponent("heed", isDirectory: true),
            home.appendingPathComponent("Desktop/heed", isDirectory: true),
            home.appendingPathComponent("Projects/heed", isDirectory: true)
        ]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("package.json").path)
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("node_modules").path)
        }
    }

    var isInstalled: Bool { installDirectory != nil }

    /// Returns once heed answers, launching it first if necessary. `progress` is
    /// called with text worth showing while the models load.
    func ensureRunning(progress: (String) -> Void) async throws {
        if await isHealthy() {
            Log.info("heed already answering at \(Settings.shared.heedBaseURL)")
            return
        }
        guard let directory = installDirectory else { throw Failure.notInstalled }

        if process?.isRunning != true {
            guard let bun = locateBun() else { throw Failure.noBun }
            progress("Starting heed…")
            try launch(bun: bun, in: directory)
        }

        // First start loads the speech and diarization models onto the Neural
        // Engine, which takes a while; later starts are quick.
        progress("Starting heed — loading models…")
        for attempt in 0..<90 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            if await isHealthy() {
                Log.info("heed is up (after \(attempt * 2)s)")
                return
            }
            if process?.isRunning == false {
                let hint = (try? String(contentsOf: Self.logURL, encoding: .utf8))?
                    .split(separator: "\n").suffix(8).joined(separator: "\n") ?? ""
                throw Failure.didNotStart(hint.isEmpty ? "the server exited on startup" : hint)
            }
            if attempt == 15 || attempt == 45 {
                progress("Still loading heed models… (\(attempt * 2)s)")
            }
        }
        throw Failure.didNotStart("it didn't answer within three minutes")
    }

    func stop() {
        guard let process, process.isRunning else {
            // We may not own the process (setup left one running) — still free the ports
            // so the next launch isn't blocked by a half-dead instance.
            killPortHolders()
            return
        }
        Log.info("Stopping heed")
        process.terminate()
        self.process = nil
        killPortHolders()
    }

    // MARK: - Internals

    private static var logURL: URL {
        AppInfo.supportDirectory.appendingPathComponent("heed-server.log")
    }

    private func launch(bun: URL, in directory: URL) throws {
        let process = Process()
        process.executableURL = bun
        process.arguments = ["run", "dev"]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [
            bun.deletingLastPathComponent().path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            environment["PATH"] ?? ""
        ].joined(separator: ":")
        process.environment = environment

        // Keep a log so a failed start can tell the user (and us) why.
        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: Self.logURL)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        self.process = process
        Log.info("Launched heed from \(directory.path) via \(bun.path)")
    }

    private func killPortHolders() {
        let ports = [URL(string: Settings.shared.heedBaseURL)?.port ?? 5170, 5002]
        let sweep = Process()
        sweep.executableURL = URL(fileURLWithPath: "/bin/sh")
        sweep.arguments = ["-c", ports.map { "lsof -ti tcp:\($0) -sTCP:LISTEN | xargs kill" }
                                      .joined(separator: "; ")]
        sweep.standardOutput = FileHandle.nullDevice
        sweep.standardError = FileHandle.nullDevice
        try? sweep.run()
        sweep.waitUntilExit()
    }

    private func isHealthy() async -> Bool {
        (try? await HeedClient.shared.health()) != nil
    }

    private func locateBun() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".bun/bin/bun"),
            URL(fileURLWithPath: "/opt/homebrew/bin/bun"),
            URL(fileURLWithPath: "/usr/local/bin/bun"),
            AppInfo.supportDirectory.appendingPathComponent("bin/bun")
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return found
        }
        // Last resort: whatever PATH the process inherited.
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["bun"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        try? which.run()
        which.waitUntilExit()
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }
}
