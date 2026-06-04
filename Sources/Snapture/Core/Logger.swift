import Foundation
import os

/// Lightweight logging wrapper around os.Logger with a file fallback so logs
/// survive even when the app runs detached from a console.
enum Log {
    private static let logger = Logger(subsystem: "com.dao.snapture", category: "app")

    private static let fileURL: URL = {
        let url = AppInfo.supportDirectory.appendingPathComponent("snapture.log")
        return url
    }()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write("INFO", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        write("ERROR", message)
    }

    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        write("DEBUG", message)
    }

    private static func write(_ level: String, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
