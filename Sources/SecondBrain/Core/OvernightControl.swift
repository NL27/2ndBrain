import Foundation
import AppKit

/// Start/stop the sandbox overnight agents without lifting hard limits,
/// and snapshot logs so the console window can show that a run actually began.
enum OvernightControl {
    static let productionDrop = URL(fileURLWithPath: "/Users/Shared/2nd-Brain-Night")
    static let developmentDrop = URL(fileURLWithPath: "/Users/Shared/2nd-Brain-Dev")

    static var vaultStop: URL {
        Settings.shared.vaultRoot.appendingPathComponent("Notes/Overnight/STOP")
    }

    static var isStopped: Bool {
        FileManager.default.fileExists(atPath: vaultStop.path)
            || FileManager.default.fileExists(atPath: productionDrop.appendingPathComponent("STOP").path)
    }

    static func stop() {
        runCtl("stop")
    }

    static func start() {
        runCtl("start")
    }

    @discardableResult
    static func runCtl(_ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [ctlScript, command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "SECOND_BRAIN_VAULT": Settings.shared.vaultRoot.path
        ]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.error("overnight-ctl \(command) failed: \(error.localizedDescription)")
            return "error: \(error.localizedDescription)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    struct Lane: Equatable {
        let name: String
        let drop: URL
        let agent: String
        let daemon: String
        var stopped: Bool
        var status: String
        var queueItem: String
        var runId: String
        var pid: String
        var pidAlive: Bool
        var queueFiles: [String]
        var daemonLoaded: Bool
        var runnerAlive: Bool
        var progressBar: String
        var progressLabel: String
        var progressValue: Double
        var working: Bool

        var headline: String {
            if stopped { return "\(name): stopped" }
            if working {
                let item = queueItem.isEmpty ? "running" : queueItem
                if !progressBar.isEmpty {
                    return "\(name): \(progressBar)  \(item)\(progressLabel.isEmpty ? "" : "  \(progressLabel)")"
                }
                return "\(name): working — \(item)"
            }
            if runnerAlive || (pidAlive && status == "running") {
                let item = queueItem.isEmpty ? "running" : queueItem
                return "\(name): working — \(item)"
            }
            if status == "running" { return "\(name): starting (pid \(pid.isEmpty ? "?" : pid))" }
            if !daemonLoaded { return "\(name): idle (Start does not need launchd)" }
            return "\(name): until-stop, idle (\(status.isEmpty ? "waiting" : status))"
        }
    }

    static func snapshot(drop: URL, name: String, agent: String, daemon: String) -> Lane {
        let fm = FileManager.default
        let stop = fm.fileExists(atPath: drop.appendingPathComponent("STOP").path)
            || fm.fileExists(atPath: vaultStop.path)
        let state = readJSON(drop.appendingPathComponent("state/current.json"))
        let status = state["status"] ?? ""
        let item = state["queueItem"] ?? ""
        let runId = state["runId"] ?? ""
        let pid = state["pid"] ?? ""
        let pidAlive = !pid.isEmpty && Self.pidAlive(pid)
        let queueDir = drop.appendingPathComponent("queue")
        let files = (try? fm.contentsOfDirectory(atPath: queueDir.path))?
            .filter { $0.hasSuffix(".md") || $0.hasSuffix(".txt") }
            .filter { !["README.md", "readme.md", "standing-mission.md"].contains($0) }
            .sorted() ?? []
        let daemonLoaded = launchdLoaded(daemon)
        let runnerAlive = processRunning(pattern: "overnight-run.sh")
            || processRunning(pattern: "/opt/homebrew/bin/cline --cwd")
        let progress = readJSON(drop.appendingPathComponent("state/progress.json"))
        let elapsed = Int(progress["elapsed_s"] ?? "") ?? 0
        let aliveProgress = (progress["alive"] ?? "").lowercased() == "true" || progress["alive"] == "1"
        let working = runnerAlive || aliveProgress
        let bar = progress["bar"] ?? ""
        let ollama = progress["ollama"] ?? ""
        let pulse = elapsed > 0 ? Double(elapsed % 30) / 30.0 : 0
        return Lane(
            name: name, drop: drop, agent: agent, daemon: daemon,
            stopped: stop, status: status, queueItem: item, runId: runId, pid: pid,
            pidAlive: pidAlive, queueFiles: files, daemonLoaded: daemonLoaded,
            runnerAlive: runnerAlive, progressBar: bar,
            progressLabel: ollama, progressValue: pulse, working: working
        )
    }

    static func logText(for lane: Lane, maxBytes: Int = 48_000) -> String {
        var chunks: [String] = [lane.headline, ""]
        chunks.append("queue: \(lane.queueFiles.isEmpty ? "(empty)" : lane.queueFiles.joined(separator: ", "))")
        chunks.append("status=\(lane.status.isEmpty ? "?" : lane.status)  item=\(lane.queueItem.isEmpty ? "-" : lane.queueItem)  pid=\(lane.pid.isEmpty ? "-" : lane.pid)\(lane.pidAlive ? " alive" : "")")
        chunks.append("daemon \(lane.daemonLoaded ? "loaded" : "NOT loaded")  runner \(lane.runnerAlive ? "alive" : "not running")")
        chunks.append("")
        let logs = lane.drop.appendingPathComponent("logs")
        chunks.append(contentsOf: tailFile(logs.appendingPathComponent("overnight.stdout.log"), title: "overnight.stdout.log", maxBytes: maxBytes / 3))
        chunks.append(contentsOf: tailFile(logs.appendingPathComponent("overnight.stderr.log"), title: "overnight.stderr.log", maxBytes: maxBytes / 4))
        chunks.append(contentsOf: tailFile(logs.appendingPathComponent("activity.jsonl"), title: "activity.jsonl", maxBytes: maxBytes / 4))
        if !lane.runId.isEmpty {
            let cline = logs.appendingPathComponent("cline-\(lane.runId).out")
            chunks.append(contentsOf: tailFile(cline, title: "cline-\(lane.runId).out", maxBytes: maxBytes / 4))
            let err = logs.appendingPathComponent("cline-\(lane.runId).err")
            chunks.append(contentsOf: tailFile(err, title: "cline-\(lane.runId).err", maxBytes: 8_000))
        }
        return redact(chunks.joined(separator: "\n"))
    }

    private static func tailFile(_ url: URL, title: String, maxBytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ["=== \(title) ===", "(no file yet)", ""]
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = handle.readDataToEndOfFile()
        var text = String(data: data, encoding: .utf8) ?? ""
        if start > 0, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["=== \(title) ===", body.isEmpty ? "(empty)" : body, ""]
    }

    private static func readJSON(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var out: [String: String] = [:]
        for (k, v) in obj {
            out[k] = "\(v)"
        }
        return out
    }

    private static func pidAlive(_ pid: String) -> Bool {
        guard let value = Int32(pid), value > 0 else { return false }
        return kill(value, 0) == 0
    }

    private static func launchdLoaded(_ label: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "system/\(label)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func processRunning(pattern: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", pattern]
        p.standardOutput = Pipe()
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func redact(_ text: String) -> String {
        var out = text
        let subs = [
            #"sk-or-[A-Za-z0-9_-]{8,}"#,
            #"sk-ant-[A-Za-z0-9_-]{8,}"#,
            #"sk-[A-Za-z0-9_-]{8,}"#,
            #"ghp_[A-Za-z0-9]{8,}"#,
            #"hf_[A-Za-z0-9]{8,}"#,
        ]
        for pattern in subs {
            if let re = try? NSRegularExpression(pattern: pattern) {
                out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "<redacted>")
            }
        }
        return out
    }

    private static var ctlScript: String {
        let bundle = Bundle.main.resourcePath.map { "\($0)/overnight-ctl.sh" }
        let support = AppInfo.supportDirectory
            .appendingPathComponent("sandbox/overnight-ctl.sh").path
        if let bundle, FileManager.default.isExecutableFile(atPath: bundle) {
            return bundle
        }
        if FileManager.default.isExecutableFile(atPath: support) {
            return support
        }
        return (Bundle.main.resourcePath ?? ".") + "/overnight-ctl.sh"
    }
}
