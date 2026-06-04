import AppKit

/// Builds and manages the menu bar status item and its menu — the only UI
/// surface of the app aside from transient panels and overlays.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var statusMessage: String = ""

    override init() {
        super.init()
        configureButton()
        statusItem.menu = buildMenu()
        HotKeyManager.shared.registerDefaults()

        NotificationCenter.default.addObserver(self, selector: #selector(recordingChanged),
                                               name: RecordingCoordinator.stateChanged, object: nil)
        NotificationCenter.default.addObserver(forName: .init("SnaptureStatus"), object: nil, queue: .main) { [weak self] note in
            self?.statusMessage = (note.object as? String) ?? ""
        }
    }

    private func configureButton() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snapture")
            button.image?.isTemplate = true
        }
    }

    @objc private func recordingChanged() {
        DispatchQueue.main.async {
            if let button = self.statusItem.button {
                let recording = RecordingCoordinator.shared.isRecording
                button.image = NSImage(systemSymbolName: recording ? "stop.circle.fill" : "camera.viewfinder",
                                       accessibilityDescription: "Snapture")
                button.image?.isTemplate = !recording
            }
        }
    }

    // MARK: - Menu construction

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        rebuild(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared

        addItem(menu, "Capture Area to Clipboard", #selector(captureArea), key: "4", mods: [.control, .option])
        addItem(menu, "OCR Region to Clipboard", #selector(captureOCR), key: "5", mods: [.control, .option])
        menu.addItem(.separator())

        let recording = RecordingCoordinator.shared.isRecording
        addItem(menu, recording ? "Stop Recording" : "Record Screen + Audio",
                #selector(toggleScreenRecording), key: "6", mods: [.control, .option])
        addItem(menu, recording && RecordingCoordinator.shared.mode == .audioOnly ? "Stop Audio" : "Record Audio Only",
                #selector(toggleAudioRecording))
        menu.addItem(.separator())

        addItem(menu, "Clipboard History…", #selector(showClipboard), key: "v", mods: [.control, .option])
        menu.addItem(.separator())

        // AI submenu
        let aiItem = NSMenuItem(title: "AI", action: nil, keyEquivalent: "")
        aiItem.submenu = buildAIMenu()
        menu.addItem(aiItem)

        // Settings submenu
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = buildSettingsMenu(s)
        menu.addItem(settingsItem)

        addItem(menu, "System Info & Recommendations…", #selector(showRecommendations))
        addItem(menu, "Open Data Folder", #selector(openSupportFolder))
        menu.addItem(.separator())

        if !statusMessage.isEmpty {
            let status = NSMenuItem(title: statusMessage, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(.separator())
        }

        let version = NSMenuItem(title: "Snapture v\(AppInfo.version)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        addItem(menu, "Quit", #selector(quit), key: "q", mods: [.command])
    }

    private func buildAIMenu() -> NSMenu {
        let menu = NSMenu()
        addItem(menu, "Ask AI about Clipboard…", #selector(askAIAboutClipboard))
        menu.addItem(.separator())
        let providerHeader = NSMenuItem(title: "Provider", action: nil, keyEquivalent: "")
        providerHeader.isEnabled = false
        menu.addItem(providerHeader)
        for provider in AIProvider.allCases {
            let item = NSMenuItem(title: provider.displayName, action: #selector(setProvider(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = provider.rawValue
            item.state = (Settings.shared.aiProvider == provider) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        addItem(menu, "Set Base URL / Model…", #selector(setAIEndpoint))
        addItem(menu, "Set API Key…", #selector(setAPIKey))
        return menu
    }

    private func buildSettingsMenu(_ s: Settings) -> NSMenu {
        let menu = NSMenu()
        addToggle(menu, "Capture System Audio", s.captureSystemAudio, #selector(toggleSystemAudio))
        addToggle(menu, "Capture Microphone", s.captureMicrophone, #selector(toggleMic))
        addToggle(menu, "Auto-Transcribe Recordings", s.autoTranscribe, #selector(toggleAutoTranscribe))
        addToggle(menu, "Speaker Diarization (WhisperX)", s.enableDiarization, #selector(toggleDiarization))
        menu.addItem(.separator())

        let backendHeader = NSMenuItem(title: "Transcription Engine", action: nil, keyEquivalent: "")
        backendHeader.isEnabled = false
        menu.addItem(backendHeader)
        for backend in TranscriptionBackend.allCases {
            let item = NSMenuItem(title: backend.displayName, action: #selector(setBackend(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = backend.rawValue
            item.state = (s.whisperBackend == backend) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let modelHeader = NSMenuItem(title: "Whisper Model", action: nil, keyEquivalent: "")
        modelHeader.isEnabled = false
        menu.addItem(modelHeader)
        for model in ["tiny.en", "base.en", "small.en", "medium.en", "large-v3"] {
            let item = NSMenuItem(title: model, action: #selector(setModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model
            item.state = (s.whisperModel == model) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - Menu helpers

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector,
                         key: String = "", mods: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = self
        menu.addItem(item)
        return item
    }

    private func addToggle(_ menu: NSMenu, _ title: String, _ on: Bool, _ action: Selector) {
        let item = addItem(menu, title, action)
        item.state = on ? .on : .off
    }

    // MARK: - Actions

    @objc private func captureArea() { ScreenshotManager.shared.captureRegionToClipboard() }
    @objc private func captureOCR() { OCRManager.shared.captureRegionAndCopyText() }
    @objc private func toggleScreenRecording() { RecordingCoordinator.shared.toggleScreenRecording() }
    @objc private func toggleAudioRecording() { RecordingCoordinator.shared.toggleAudioRecording() }
    @objc private func showClipboard() { ClipboardHistoryController.shared.toggle(relativeTo: statusItem.button) }
    @objc private func openSupportFolder() { NSWorkspace.shared.open(AppInfo.supportDirectory) }
    @objc private func showRecommendations() { SystemProfiler.shared.presentRecommendation(SystemProfiler.shared.recommend()) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleSystemAudio() { Settings.shared.captureSystemAudio.toggle() }
    @objc private func toggleMic() { Settings.shared.captureMicrophone.toggle() }
    @objc private func toggleAutoTranscribe() { Settings.shared.autoTranscribe.toggle() }
    @objc private func toggleDiarization() { Settings.shared.enableDiarization.toggle() }

    @objc private func setBackend(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let b = TranscriptionBackend(rawValue: raw) {
            Settings.shared.whisperBackend = b
        }
    }

    @objc private func setModel(_ sender: NSMenuItem) {
        if let model = sender.representedObject as? String { Settings.shared.whisperModel = model }
    }

    @objc private func setProvider(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let p = AIProvider(rawValue: raw) {
            Settings.shared.aiProvider = p
        }
    }

    @objc private func setAIEndpoint() {
        guard let base = prompt(title: "AI Base URL",
                                message: "OpenAI-compatible base URL (e.g. http://localhost:11434/v1).",
                                defaultValue: Settings.shared.aiBaseURL) else { return }
        Settings.shared.aiBaseURL = base
        if let model = prompt(title: "AI Model", message: "Model name (e.g. llama3.1, gpt-4o-mini).",
                              defaultValue: Settings.shared.aiModel) {
            Settings.shared.aiModel = model
        }
    }

    @objc private func setAPIKey() {
        let provider = Settings.shared.aiProvider
        guard let key = prompt(title: "API Key for \(provider.displayName)",
                               message: "Stored securely in the macOS Keychain.",
                               defaultValue: Keychain.get(account: provider.rawValue) ?? "",
                               secure: true) else { return }
        Keychain.set(key, account: provider.rawValue)
    }

    @objc private func askAIAboutClipboard() {
        let latestText = ClipboardManager.shared.items.first(where: { $0.kind == .text })?.text ?? ""
        guard let question = prompt(title: "Ask AI",
                                    message: "Your prompt. The most recent clipboard text is attached as context.",
                                    defaultValue: "Summarize this:") else { return }
        Task {
            do {
                let messages = [
                    ChatMessage(role: "system", content: "You are a concise, helpful assistant."),
                    ChatMessage(role: "user", content: latestText.isEmpty ? question : "\(question)\n\n---\n\(latestText)")
                ]
                let answer = try await AIConnector.shared.complete(messages: messages)
                await MainActor.run { self.presentAIResult(answer) }
            } catch {
                await MainActor.run {
                    self.showAlert(title: "AI Error", message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Dialog helpers

    private func presentAIResult(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "AI Response"
        alert.informativeText = text
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func prompt(title: String, message: String, defaultValue: String, secure: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field: NSTextField = secure
            ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            : NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
