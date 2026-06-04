import AppKit

/// A single entry in the clipboard history.
struct ClipboardItem: Identifiable, Codable {
    enum Kind: String, Codable { case text, image, file }
    let id: UUID
    let kind: Kind
    var text: String?
    var imageFilename: String?      // stored relative to the images directory
    var filePaths: [String]?
    let date: Date
    var sourceApp: String?
    var pinned: Bool

    var preview: String {
        switch kind {
        case .text: return text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case .image: return "Image"
        case .file: return (filePaths ?? []).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        }
    }
}

/// Monitors the system pasteboard and maintains a persisted history with
/// quick re-use — analogous to the Paste app from Setapp.
final class ClipboardManager {
    static let shared = ClipboardManager()
    private init() { load() }

    private(set) var items: [ClipboardItem] = []
    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var ignoreNextChange = false

    /// Posted whenever the history changes so any open UI can refresh.
    static let didChangeNotification = Notification.Name("ClipboardManagerDidChange")

    private var storeURL: URL { AppInfo.supportDirectory.appendingPathComponent("clipboard.json") }
    private var imagesDir: URL {
        let dir = AppInfo.supportDirectory.appendingPathComponent("clipboard-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer!, forMode: .common)
        Log.info("Clipboard monitoring started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Polling

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        if ignoreNextChange { ignoreNextChange = false; return }

        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName

        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], let image = images.first {
            store(image: image, sourceApp: sourceApp)
        } else if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty,
                  urls.allSatisfy({ $0.isFileURL }) {
            add(ClipboardItem(id: UUID(), kind: .file, text: nil, imageFilename: nil,
                              filePaths: urls.map { $0.path }, date: Date(), sourceApp: sourceApp, pinned: false))
        } else if let string = pb.string(forType: .string), !string.isEmpty {
            add(ClipboardItem(id: UUID(), kind: .text, text: string, imageFilename: nil,
                              filePaths: nil, date: Date(), sourceApp: sourceApp, pinned: false))
        }
    }

    /// Called by ScreenshotManager when it writes an image to the pasteboard,
    /// so we record it without double-counting on the next poll.
    func noteInternalImageCopy(_ image: NSImage) {
        lastChangeCount = NSPasteboard.general.changeCount
        ignoreNextChange = true
        store(image: image, sourceApp: AppInfo.name)
    }

    private func store(image: NSImage, sourceApp: String?) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let filename = "\(UUID().uuidString).png"
        let url = imagesDir.appendingPathComponent(filename)
        try? png.write(to: url)
        add(ClipboardItem(id: UUID(), kind: .image, text: nil, imageFilename: filename,
                          filePaths: nil, date: Date(), sourceApp: sourceApp, pinned: false))
    }

    // MARK: - Mutations

    private func add(_ item: ClipboardItem) {
        // De-duplicate consecutive identical text entries.
        if item.kind == .text, let first = items.first, first.kind == .text, first.text == item.text {
            return
        }
        items.insert(item, at: 0)
        trim()
        save()
        notifyChange()
    }

    private func trim() {
        let limit = max(10, Settings.shared.clipboardHistoryLimit)
        guard items.count > limit else { return }
        let pinned = items.filter { $0.pinned }
        var unpinned = items.filter { !$0.pinned }
        if unpinned.count > limit {
            let removed = unpinned[limit...]
            for item in removed { deleteBackingFile(item) }
            unpinned = Array(unpinned.prefix(limit))
        }
        items = (pinned + unpinned).sorted { $0.date > $1.date }
    }

    func imageURL(for item: ClipboardItem) -> URL? {
        guard let name = item.imageFilename else { return nil }
        return imagesDir.appendingPathComponent(name)
    }

    /// Re-copies an item to the pasteboard and optionally pastes it into the
    /// frontmost app by synthesizing Cmd+V.
    func copyToPasteboard(_ item: ClipboardItem, paste: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        ignoreNextChange = true
        switch item.kind {
        case .text:
            if let text = item.text { pb.setString(text, forType: .string) }
        case .image:
            if let url = imageURL(for: item), let image = NSImage(contentsOf: url) {
                pb.writeObjects([image])
            }
        case .file:
            let urls = (item.filePaths ?? []).map { URL(fileURLWithPath: $0) as NSURL }
            if !urls.isEmpty { pb.writeObjects(urls) }
        }
        lastChangeCount = pb.changeCount
        if paste {
            // Auto-paste needs Accessibility. Only do it when already granted so
            // we never trigger a permission prompt on a simple click — otherwise
            // just leave it on the clipboard for a manual ⌘V.
            if Permissions.hasAccessibility() {
                Self.synthesizePaste()
            } else {
                NotificationCenter.default.post(name: .init("SnaptureStatus"),
                                                object: "Copied — press ⌘V to paste (enable Auto-Paste in Settings)")
            }
        }
    }

    func togglePin(_ item: ClipboardItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].pinned.toggle()
        items.sort { ($0.pinned ? 1 : 0, $0.date) > ($1.pinned ? 1 : 0, $1.date) }
        save()
        notifyChange()
    }

    func delete(_ item: ClipboardItem) {
        deleteBackingFile(item)
        items.removeAll { $0.id == item.id }
        save()
        notifyChange()
    }

    func clearAll() {
        items.forEach { deleteBackingFile($0) }
        items.removeAll()
        save()
        notifyChange()
    }

    private func deleteBackingFile(_ item: ClipboardItem) {
        if let url = imageURL(for: item) { try? FileManager.default.removeItem(at: url) }
    }

    private static func synthesizePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // 'v'
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - Persistence

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: storeURL)
        } catch {
            Log.error("Clipboard save failed: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) else { return }
        items = decoded
    }
}
