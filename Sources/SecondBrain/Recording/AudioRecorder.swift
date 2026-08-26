import AVFoundation

/// Records the default microphone input to an .m4a file. Used standalone for
/// audio-only capture, or alongside ScreenRecorder for mic + screen.
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private(set) var outputURL: URL?
    private(set) var isRecording = false

    func start() throws {
        let url = Recordings.newURL(ext: "m4a", prefix: "mic")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        guard recorder.record() else {
            throw NSError(domain: "Snapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone recorder failed to start"])
        }
        self.recorder = recorder
        self.outputURL = url
        isRecording = true
        Log.info("Microphone recording started -> \(url.lastPathComponent)")
    }

    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        recorder?.stop()
        isRecording = false
        let url = outputURL
        recorder = nil
        Log.info("Microphone recording finished -> \(url?.lastPathComponent ?? "nil")")
        return url
    }
}
