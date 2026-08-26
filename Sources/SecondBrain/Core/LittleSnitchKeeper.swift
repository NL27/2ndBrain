import Foundation

/// Re-enables Little Snitch's network filter every three hours.
///
/// Unlicensed demo mode turns the filter off after 3h; you may turn it back
/// on as often as you like (same as the status menu). This does not patch
/// Little Snitch or write license files.
enum LittleSnitchKeeper {
    private static var timer: Timer?

    static func start() {
        timer?.invalidate()
        let interval: TimeInterval = 3 * 60 * 60
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            run()
        }
        timer?.tolerance = 120
        // First pass shortly after launch so a reboot does not wait 3 hours.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) {
            run()
        }
    }

    static func run() {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                Log.info("Little Snitch keeper finished (status \(process.terminationStatus))")
            } catch {
                Log.error("Little Snitch keeper failed to start: \(error.localizedDescription)")
            }
        }
    }

    private static var scriptPath: String {
        if let bundled = Bundle.main.path(forResource: "little-snitch-keeper", ofType: "sh") {
            return bundled
        }
        let support = AppInfo.supportDirectory
            .appendingPathComponent("sandbox/little-snitch-keeper.sh").path
        if FileManager.default.isExecutableFile(atPath: support) {
            return support
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/little-snitch-keeper.sh").path
    }
}
