import AppKit
import ScreenCaptureKit

/// Orchestrates screen + system audio + microphone recording and post-capture
/// transcription. Supports recording a chosen display, the display under the
/// cursor, or every connected display at once (one file per display).
final class RecordingCoordinator {
    static let shared = RecordingCoordinator()
    private init() {}

    enum Mode { case screen, audioOnly }

    /// Which display(s) to record.
    enum ScreenSelection {
        case all
        case display(CGDirectDisplayID)
    }

    struct DisplayInfo {
        let id: CGDirectDisplayID
        let name: String
        let frame: CGRect
        let scale: CGFloat
    }

    private var screenRecorders: [ScreenRecorder] = []
    private let audioRecorder = AudioRecorder()
    private(set) var isRecording = false
    private(set) var mode: Mode = .screen

    /// Posted when recording state changes so the menu can update its title.
    static let stateChanged = Notification.Name("RecordingStateChanged")

    // MARK: - Display discovery

    /// All currently connected displays (synchronous, for menu building).
    static func availableDisplays() -> [DisplayInfo] {
        NSScreen.screens.map { screen in
            DisplayInfo(id: screen.displayID,
                        name: screen.localizedName,
                        frame: screen.frame,
                        scale: screen.backingScaleFactor)
        }
    }

    /// The display the mouse pointer is currently on.
    static func displayUnderCursor() -> CGDirectDisplayID {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
        return screen?.displayID ?? CGMainDisplayID()
    }

    // MARK: - Public control

    func toggleScreenRecording(selection: ScreenSelection) {
        if isRecording { stop() } else { startScreen(selection: selection) }
    }

    /// The display a window sits on, used so the quick-actions bar records the
    /// screen it is currently on rather than wherever the pointer happens to be.
    @MainActor
    static func display(containing window: NSWindow) -> CGDirectDisplayID {
        let centre = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let screen = window.screen
            ?? NSScreen.screens.first { NSMouseInRect(centre, $0.frame, false) }
            ?? NSScreen.main
        return screen?.displayID ?? CGMainDisplayID()
    }

    func toggleAudioRecording() {
        if isRecording { stop() } else { startAudioOnly() }
    }

    func stopIfRecording() {
        if isRecording { stop() }
    }

    private func startScreen(selection: ScreenSelection) {
        guard Permissions.hasScreenRecording() else {
            DispatchQueue.main.async { Permissions.guideScreenRecording() }
            return
        }
        mode = .screen
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let displays = resolveDisplays(selection, from: content.displays)
                guard !displays.isEmpty else {
                    Log.error("No display available for recording"); return
                }

                // Only the first stream captures system audio to avoid recording
                // it multiple times when recording several displays at once.
                var captureAudio = Settings.shared.captureSystemAudio
                // Panning the crop only makes sense for a single display.
                let followMouse = Settings.shared.followMouseWhileRecording && displays.count == 1
                for display in displays {
                    let recorder = ScreenRecorder()
                    try await recorder.start(display: display,
                                             captureSystemAudio: captureAudio,
                                             followMouse: followMouse)
                    screenRecorders.append(recorder)
                    captureAudio = false
                }
                startMicIfEnabled()
                let videoURL = screenRecorders.first?.outputURL
                await MainActor.run {
                    self.startInputOverlayIfEnabled(displayIDs: displays.map(\.displayID),
                                                    videoURL: videoURL)
                    self.setRecording(true)
                }
                Log.info("Recording \(displays.count) display(s)")
            } catch {
                Log.error("Failed to start screen recording: \(error)")
                await self.stopAllScreenRecorders()
            }
        }
    }

    private func resolveDisplays(_ selection: ScreenSelection, from available: [SCDisplay]) -> [SCDisplay] {
        switch selection {
        case .all:
            return available
        case .display(let id):
            if let match = available.first(where: { $0.displayID == id }) { return [match] }
            if let main = available.first(where: { $0.displayID == CGMainDisplayID() }) { return [main] }
            return Array(available.prefix(1))
        }
    }

    private func startAudioOnly() {
        mode = .audioOnly
        ensureMic { granted in
            guard granted else { return }
            do {
                try self.audioRecorder.start()
                self.setRecording(true)
            } catch {
                Log.error("Failed to start audio recording: \(error)")
            }
        }
    }

    /// Shows click/keystroke visuals and the pointer ring on the recorded screen
    /// so they're captured in the video, and logs the actions beside it.
    /// Only meaningful for a single display.
    @MainActor
    private func startInputOverlayIfEnabled(displayIDs: [CGDirectDisplayID], videoURL: URL?) {
        let s = Settings.shared
        guard s.showInputOverlay || s.showMouseRing,
              let id = displayIDs.first, displayIDs.count == 1,
              let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { return }
        let logURL = videoURL?.deletingPathExtension().appendingPathExtension("input.jsonl")
        InputOverlay.shared.start(on: screen,
                                  options: .init(showClicksAndKeys: s.showInputOverlay,
                                                 showMouseRing: s.showMouseRing,
                                                 logURL: logURL))
    }

    private func startMicIfEnabled() {
        guard Settings.shared.captureMicrophone else { return }
        ensureMic { granted in
            guard granted else { return }
            try? self.audioRecorder.start()
        }
    }

    private func ensureMic(_ completion: @escaping (Bool) -> Void) {
        switch Permissions.microphoneStatus() {
        case .authorized: completion(true)
        case .notDetermined: Permissions.requestMicrophone(completion)
        default:
            Permissions.openMicrophoneSettings()
            completion(false)
        }
    }

    func stop() {
        Task {
            await MainActor.run { InputOverlay.shared.stop() }
            var audioForTranscription: URL?
            let micURL = audioRecorder.stop()
            if mode == .screen {
                let movURLs = await stopAllScreenRecorders()
                audioForTranscription = micURL ?? movURLs.first
                if !movURLs.isEmpty { revealInFinder(movURLs) }
            } else {
                audioForTranscription = micURL
                if let micURL { revealInFinder([micURL]) }
            }
            await MainActor.run { self.setRecording(false) }

            guard Settings.shared.autoTranscribe, let audioURL = audioForTranscription else { return }
            // Heed can't share the microphone with 2ⁿᵈ Brain's own recorder, so
            // live multi-speaker captions aren't available here. After the fact we
            // ask, and run Tiron when there was more than one voice.
            let useTiron = await MainActor.run { Self.askIfMultiSpeaker() }
                && TranscriptionManager.shared.isInstalled(.tiron)
            if useTiron {
                do {
                    let text = try await TranscriptionManager.shared.transcript(for: audioURL, using: .tiron)
                    let outURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
                    try text.write(to: outURL, atomically: true, encoding: .utf8)
                    Log.info("Tiron transcript written -> \(outURL.lastPathComponent)")
                    await MainActor.run {
                        NotificationCenter.default.post(name: .init("SecondBrainStatus"),
                                                        object: "Transcript ready: \(outURL.lastPathComponent)")
                        NSWorkspace.shared.activateFileViewerSelecting([outURL])
                        HUD.shared.show("Speakers labelled", symbol: "person.2.wave.2")
                    }
                } catch {
                    Log.error("Tiron after recording failed: \(error.localizedDescription)")
                    TranscriptionManager.shared.transcribe(url: audioURL)
                }
            } else {
                TranscriptionManager.shared.transcribe(url: audioURL)
            }
        }
    }

    /// Heed already labels speakers during live sessions; for 2ⁿᵈ Brain's own
    /// recordings we have to ask, because we can't tell from a mixed audio track.
    @MainActor
    private static func askIfMultiSpeaker() -> Bool {
        guard TranscriptionManager.shared.isInstalled(.tiron) else { return false }
        let alert = NSAlert()
        alert.messageText = "Did more than one person speak?"
        alert.informativeText = """
        2ⁿᵈ Brain can re-transcribe this recording with Tiron, which labels who \
        said what — including people talking over each other.

        For live captions with speakers while the meeting is still going, use \
        Live Transcription (⌃⌥T) instead of screen/audio recording.
        """
        alert.addButton(withTitle: "Yes — Label Speakers")
        alert.addButton(withTitle: "No — Plain Transcript")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    @discardableResult
    private func stopAllScreenRecorders() async -> [URL] {
        var urls: [URL] = []
        for recorder in screenRecorders {
            if let url = await recorder.stop() { urls.append(url) }
        }
        screenRecorders.removeAll()
        return urls
    }

    private func setRecording(_ value: Bool) {
        isRecording = value
        NotificationCenter.default.post(name: Self.stateChanged, object: nil)
    }

    private func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }
}
