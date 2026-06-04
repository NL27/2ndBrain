import AppKit
import ScreenCaptureKit

/// Orchestrates screen + system audio + microphone recording and post-capture
/// transcription.
final class RecordingCoordinator {
    static let shared = RecordingCoordinator()
    private init() {}

    enum Mode { case screen, audioOnly }

    private let screenRecorder = ScreenRecorder()
    private let audioRecorder = AudioRecorder()
    private(set) var isRecording = false
    private(set) var mode: Mode = .screen

    /// Posted when recording state changes so the menu can update its title.
    static let stateChanged = Notification.Name("RecordingStateChanged")

    func toggleScreenRecording() {
        if isRecording { stop() } else { startScreen() }
    }

    func toggleAudioRecording() {
        if isRecording { stop() } else { startAudioOnly() }
    }

    private func startScreen() {
        guard Permissions.hasScreenRecording() else {
            Permissions.requestScreenRecording()
            Permissions.openScreenRecordingSettings()
            return
        }
        mode = .screen
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                        ?? content.displays.first else {
                    Log.error("No display available for recording"); return
                }
                try await screenRecorder.start(display: display, captureSystemAudio: Settings.shared.captureSystemAudio)
                startMicIfEnabled()
                await MainActor.run { self.setRecording(true) }
            } catch {
                Log.error("Failed to start screen recording: \(error)")
            }
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
                let movURL = await screenRecorder.stop()
                audioForTranscription = micURL ?? movURL
                if let movURL { revealInFinder(movURL) }
            } else {
                audioForTranscription = micURL
                if let micURL { revealInFinder(micURL) }
            }
            await MainActor.run { self.setRecording(false) }

            if Settings.shared.autoTranscribe, let audioURL = audioForTranscription {
                TranscriptionManager.shared.transcribe(url: audioURL)
            }
        }
    }

    private func setRecording(_ value: Bool) {
        isRecording = value
        NotificationCenter.default.post(name: Self.stateChanged, object: nil)
    }

    private func revealInFinder(_ url: URL) {
        DispatchQueue.main.async {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
