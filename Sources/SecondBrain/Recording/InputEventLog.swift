import AppKit

/// Records what the user actually did during a recording — every click (with the
/// button that was used) and every keystroke combination, each stamped with the
/// time since the recording started.
///
/// The output is JSON Lines next to the video, so a person or a model can read
/// the session back as an ordered list of actions and reproduce it.
final class InputEventLog {
    /// One captured input.
    struct Event: Encodable {
        /// Seconds since the recording started.
        let t: Double
        /// "click", "key", "scroll" or "session".
        let type: String
        var button: String?
        var buttonNumber: Int?
        var clickCount: Int?
        /// Pointer position in the recorded display's own coordinates, top-left origin.
        var x: Double?
        var y: Double?
        var key: String?
        var combo: String?
        var keyCode: Int?
        var modifiers: [String]?
        /// Frontmost application at the time, which is what makes a replay
        /// reproducible rather than just a list of coordinates.
        var app: String?
    }

    private let url: URL
    private let start: Date
    private let queue = DispatchQueue(label: "com.dao.secondbrain.input-log", qos: .utility)
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return encoder
    }()

    init(url: URL, start: Date = Date()) {
        self.url = url
        self.start = start
        FileManager.default.createFile(atPath: url.path, contents: nil)
        writeHeader()
    }

    var fileURL: URL { url }

    private func writeHeader() {
        var header = Event(t: 0, type: "session")
        header.app = "\(AppInfo.name) \(AppInfo.version)"
        header.combo = ISO8601DateFormatter().string(from: start)
        append(header)
    }

    func record(_ event: Event) {
        append(event)
    }

    /// Seconds since the recording began, for callers building events.
    func elapsed() -> Double {
        Date().timeIntervalSince(start)
    }

    private func append(_ event: Event) {
        queue.async { [encoder, url] in
            guard var data = try? encoder.encode(event) else { return }
            data.append(0x0A) // newline
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// Waits for buffered writes so the file is complete when recording stops.
    func flush() {
        queue.sync { }
    }
}

// MARK: - Naming

enum InputNaming {
    /// Human name for a mouse button, including the extra side buttons that
    /// multi-button mice report as button 3 and up.
    static func mouseButton(_ number: Int) -> String {
        switch number {
        case 0: return "left"
        case 1: return "right"
        case 2: return "middle"
        case 3: return "side-back"
        case 4: return "side-forward"
        default: return "button-\(number + 1)"
        }
    }

    static func symbol(forMouseButton number: Int) -> String {
        switch number {
        case 0: return "L"
        case 1: return "R"
        case 2: return "M"
        default: return "\(number + 1)"
        }
    }

    /// Modifier names in a stable order, suitable for machine reading.
    static func modifierNames(_ flags: NSEvent.ModifierFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.control) { names.append("control") }
        if flags.contains(.option) { names.append("option") }
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.command) { names.append("command") }
        if flags.contains(.function) { names.append("function") }
        return names
    }

    /// Symbolic modifier prefix in the order macOS displays them, e.g. "⌃⌥⇧⌘".
    static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out
    }

    /// Readable name for a key, preferring symbols for the special keys.
    static func keyName(_ event: NSEvent) -> String? {
        let named: [UInt16: String] = [
            36: "return", 48: "tab", 49: "space", 51: "delete", 53: "escape",
            76: "enter", 115: "home", 116: "page-up", 117: "forward-delete",
            119: "end", 121: "page-down",
            123: "left", 124: "right", 125: "down", 126: "up"
        ]
        if let name = named[event.keyCode] { return name }
        let characters = event.charactersIgnoringModifiers ?? ""
        guard let first = characters.first, !first.isNewline else { return nil }
        return String(first).lowercased()
    }

    /// Compact display form for the on-screen caption, e.g. "⌘⇧4" or "⏎".
    static func keySymbol(_ event: NSEvent) -> String? {
        let symbols: [UInt16: String] = [
            36: "⏎", 48: "⇥", 49: "space", 51: "⌫", 53: "esc",
            76: "⌤", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        let prefix = modifierSymbols(event.modifierFlags)
        if let symbol = symbols[event.keyCode] { return prefix + symbol }
        let characters = event.charactersIgnoringModifiers ?? ""
        guard !characters.isEmpty else { return prefix.isEmpty ? nil : prefix }
        return prefix + characters.uppercased()
    }
}

private extension FileManager {
    func createFile(atPath path: String, contents: Data?) {
        if !fileExists(atPath: path) {
            createFile(atPath: path, contents: contents, attributes: nil)
        }
    }
}
