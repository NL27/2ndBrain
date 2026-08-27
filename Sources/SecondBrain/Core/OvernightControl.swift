import Foundation
import AppKit

/// Start/stop the sandbox overnight agents without lifting hard limits.
enum OvernightControl {
    static var vaultStop: URL {
        Settings.shared.vaultRoot.appendingPathComponent("Notes/Overnight/STOP")
    }

    static var isStopped: Bool {
        FileManager.default.fileExists(atPath: vaultStop.path)
            || FileManager.default.fileExists(atPath: "/Users/Shared/2nd-Brain-Night/STOP")
    }

    static func stop() {
        runCtl("stop")
    }

    static func start() {
        runCtl("start")
    }

    @discardableResult
    private static func runCtl(_ command: String) -> String {
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
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
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
