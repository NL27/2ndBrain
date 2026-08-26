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
                for display in displays {
                    let recorder = ScreenRecorder()
                    try await recorder.start(display: display, captureSystemAudio: captureAudio)
                    screenRecorders.append(recorder)
                    captureAudio = false
                }
                startMicIfEnabled()
                await MainActor.run { self.setRecording(true) }
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

            if Settings.shared.autoTranscribe, let audioURL = audioForTranscription {
                TranscriptionManager.shared.transcribe(url: audioURL)
            }
        }
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
