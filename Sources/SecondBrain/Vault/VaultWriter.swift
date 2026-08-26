import AppKit
import UniformTypeIdentifiers

/// Files captures into the Obsidian vault and pairs each one with a markdown
/// note carrying tags.
///
/// Obsidian builds its graph from links and tags, not folders, so a binary on
/// its own is invisible there. Every item therefore gets a sidecar note that
/// embeds the media and declares nested tags (`capture/screenshot`,
/// `app/safari`), which is what makes things findable and connectable later.
enum VaultWriter {
    /// Where an item belongs, which decides both the folder and the base tag.
    enum Kind {
        case screenshot
        case ocr
        case screenRecording
        case audioRecording
        case transcript
        case liveTranscript

        var folder: String {
            switch self {
            case .screenshot, .ocr: return "Captures"
            case .screenRecording, .audioRecording: return "Recordings"
            case .transcript, .liveTranscript: return "Meetings"
            }
        }

        var tag: String {
            switch self {
            case .screenshot: return "capture/screenshot"
            case .ocr: return "capture/ocr"
            case .screenRecording: return "recording/screen"
            case .audioRecording: return "recording/audio"
            case .transcript: return "transcript"
            case .liveTranscript: return "transcript/live"
            }
        }

        var frontmatterType: String {
            switch self {
            case .screenshot: return "screenshot"
            case .ocr: return "ocr"
            case .screenRecording: return "screen-recording"
            case .audioRecording: return "audio-recording"
            case .transcript: return "transcript"
            case .liveTranscript: return "live-transcript"
            }
        }

        var title: String {
            switch self {
            case .screenshot: return "Screenshot"
            case .ocr: return "OCR"
            case .screenRecording: return "Screen recording"
            case .audioRecording: return "Audio recording"
            case .transcript: return "Transcript"
            case .liveTranscript: return "Live transcript"
            }
        }
    }

    // MARK: - Public API

    static var isEnabled: Bool { Settings.shared.saveCapturesToVault }

    /// Saves an image plus its note. Returns the image URL inside the vault.
    @discardableResult
    static func save(image: CGImage, pointSize: NSSize, kind: Kind = .screenshot) -> URL? {
        guard isEnabled else { return nil }
        guard let png = ScreenshotManager.pngData(from: image, pointSize: pointSize) else {
            Log.error("Vault: could not encode PNG for \(kind.frontmatterType)")
            return nil
        }

        let stamp = Date()
        let base = filename(for: kind, at: stamp)
        guard let mediaURL = write(data: png, named: "\(base).png", in: kind.folder) else { return nil }

        let extra = [
            "dimensions: \"\(image.width)x\(image.height)\"",
            "source: \(yaml(frontApp() ?? "unknown"))",
        ]
        writeNote(
            kind: kind,
            base: base,
            at: stamp,
            extraFrontmatter: extra,
            body: "![[\(mediaURL.lastPathComponent)]]"
        )
        return mediaURL
    }

    /// Saves recognised text as a note. There is no media file: the text is the
    /// artefact, so it lives in the note body where Omnisearch can index it.
    @discardableResult
    static func save(text: String, kind: Kind = .ocr) -> URL? {
        guard isEnabled, !text.isEmpty else { return nil }
        if let hit = SecretGuard.firstHit(in: text) {
            Log.info("Vault: skipped filing \(kind.frontmatterType) — looks like a \(hit.kind)")
            return nil
        }

        let stamp = Date()
        let base = filename(for: kind, at: stamp)
        let extra = [
            "characters: \(text.count)",
            "source: \(yaml(frontApp() ?? "unknown"))",
        ]
        return writeNote(
            kind: kind,
            base: base,
            at: stamp,
            extraFrontmatter: extra,
            body: text
        )
    }

    /// Moves a finished recording out of the app's working directory and into
    /// the vault, then writes its note. A move, not a copy — these files run to
    /// gigabytes and both locations are on the same volume.
    @discardableResult
    static func adopt(
        mediaAt source: URL,
        kind: Kind,
        extraTags: [String] = [],
        companions: [URL] = []
    ) -> URL? {
        guard isEnabled else { return nil }

        let stamp = (try? source.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        guard let mediaURL = move(source, into: kind.folder) else { return nil }

        // Things written beside the media during capture, like the input event
        // log, belong with it rather than orphaned in the working directory.
        var tags = extraTags
        for companion in companions where FileManager.default.fileExists(atPath: companion.path) {
            if move(companion, into: kind.folder) != nil, companion.pathExtension == "jsonl" {
                tags.append("input/tracked")
            }
        }

        var extra: [String] = []
        if let size = try? mediaURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            extra.append("bytes: \(size)")
        }
        writeNote(
            kind: kind,
            base: mediaURL.deletingPathExtension().lastPathComponent,
            at: stamp,
            extraFrontmatter: extra,
            extraTags: tags,
            body: "![[\(mediaURL.lastPathComponent)]]"
        )
        return mediaURL
    }

    /// Writes a transcript note that links back to the recording it came from.
    @discardableResult
    static func saveTranscript(
        _ text: String,
        for media: URL?,
        kind: Kind = .transcript,
        speakers: Int? = nil
    ) -> URL? {
        guard isEnabled, !text.isEmpty else { return nil }

        let stamp = Date()
        let base = media?.deletingPathExtension().lastPathComponent
            ?? filename(for: kind, at: stamp)

        var extra = ["words: \(text.split(whereSeparator: \.isWhitespace).count)"]
        var tags: [String] = []
        if let speakers {
            extra.append("speakers: \(speakers)")
            tags.append("speakers/\(speakers)")
        }

        var body = ""
        if let media {
            extra.append("recording: \"[[\(media.lastPathComponent)]]\"")
            body += "Recording: ![[\(media.lastPathComponent)]]\n\n"
        }
        body += text

        return writeNote(
            kind: kind,
            base: "\(base) transcript",
            at: stamp,
            extraFrontmatter: extra,
            extraTags: tags,
            body: body
        )
    }

    // MARK: - Note construction

    @discardableResult
    private static func writeNote(
        kind: Kind,
        base: String,
        at stamp: Date,
        extraFrontmatter: [String] = [],
        extraTags: [String] = [],
        body: String
    ) -> URL? {
        var tags = [kind.tag, "date/\(Self.dayFormatter.string(from: stamp))"]
        if let app = frontApp() { tags.append("app/\(slug(app))") }
        tags.append(contentsOf: extraTags)

        var lines = ["---"]
        lines.append("type: \(kind.frontmatterType)")
        lines.append("created: \(Self.isoFormatter.string(from: stamp))")
        lines.append(contentsOf: extraFrontmatter)
        lines.append("tags: [\(tags.joined(separator: ", "))]")
        lines.append("---")
        lines.append("")
        lines.append("# \(kind.title) — \(Self.titleFormatter.string(from: stamp))")
        lines.append("")
        lines.append(body)
        lines.append("")
        // Inline tags as well as frontmatter: Obsidian's tag pane and graph pick
        // up both, but only inline tags render as clickable in reading view.
        lines.append(tags.map { "#\($0)" }.joined(separator: " "))
        lines.append("")

        let text = lines.joined(separator: "\n")
        guard let data = text.data(using: .utf8) else { return nil }
        return write(data: data, named: "\(base).md", in: kind.folder)
    }

    // MARK: - Filesystem

    private static func folderURL(_ name: String) -> URL? {
        let url = Settings.shared.vaultRoot.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            Log.error("Vault: could not create \(url.path): \(error)")
            reportIfDenied(error)
            return nil
        }
    }

    /// A vault on the Desktop needs Files and Folders access. Without this the
    /// only symptom would be captures quietly never appearing in Obsidian, so
    /// say it once rather than logging into the void.
    private static var warnedAboutAccess = false

    private static func reportIfDenied(_ error: Error) {
        let code = (error as NSError).code
        guard code == NSFileReadNoPermissionError || code == NSFileWriteNoPermissionError,
              !warnedAboutAccess else { return }
        warnedAboutAccess = true

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "\(AppInfo.name) can't write to your vault"
            alert.informativeText = """
            Captures are still going to the clipboard, but they can't be filed into
            \(Settings.shared.vaultRoot.path).

            macOS guards the Desktop folder. Allow \(AppInfo.name) under Privacy & \
            Security → Files and Folders.
            """
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                Permissions.openFilesAndFoldersSettings()
            }
        }
    }

    private static func write(data: Data, named name: String, in folder: String) -> URL? {
        guard let dir = folderURL(folder) else { return nil }
        let url = uniqueURL(in: dir, named: name)
        do {
            try data.write(to: url)
            Log.info("Vault: wrote \(folder)/\(url.lastPathComponent)")
            return url
        } catch {
            Log.error("Vault: could not write \(url.path): \(error)")
            reportIfDenied(error)
            return nil
        }
    }

    private static func move(_ source: URL, into folder: String) -> URL? {
        guard let dir = folderURL(folder) else { return nil }
        let url = uniqueURL(in: dir, named: source.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: source, to: url)
            Log.info("Vault: moved \(source.lastPathComponent) -> \(folder)/\(url.lastPathComponent)")
            return url
        } catch {
            Log.error("Vault: could not move \(source.path): \(error)")
            return nil
        }
    }

    /// Never clobber an existing file; captures in the same second are possible.
    private static func uniqueURL(in dir: URL, named name: String) -> URL {
        let candidate = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let stem = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        for index in 2...99 {
            let next = dir.appendingPathComponent(
                ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            )
            if !FileManager.default.fileExists(atPath: next.path) { return next }
        }
        return candidate
    }

    // MARK: - Naming

    private static func filename(for kind: Kind, at stamp: Date) -> String {
        "\(Self.fileStampFormatter.string(from: stamp)) \(kind.frontmatterType)"
    }

    /// Frontmost app name, used for the `app/…` tag so captures group by where
    /// they came from. Our own overlays are never frontmost at capture time.
    private static func frontApp() -> String? {
        guard let name = NSWorkspace.shared.frontmostApplication?.localizedName,
              name != AppInfo.name, name != AppInfo.appFileName else { return nil }
        return name
    }

    /// A double-quoted YAML scalar. App names can contain colons and `#`, either
    /// of which would otherwise break the frontmatter block.
    private static func yaml(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Tag-safe: Obsidian tags cannot contain spaces, and `/` starts a nested level.
    private static func slug(_ value: String) -> String {
        let allowed = value.lowercased().map { character -> Character in
            character.isLetter || character.isNumber || character == "-" ? character : "-"
        }
        return String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }

    // MARK: - Formatters

    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
