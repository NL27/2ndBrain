import AVFoundation
import ScreenCaptureKit
import AppKit

/// Records a display (video) plus system audio to a .mov file using
/// ScreenCaptureKit + AVAssetWriter.
final class ScreenRecorder: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private let sampleQueue = DispatchQueue(label: "com.dao.snapture.screen-sample")

    private(set) var outputURL: URL?
    private(set) var isRecording = false

    func start(display: SCDisplay, captureSystemAudio: Bool) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * (NSScreen.main?.backingScaleFactor ?? 2))
        config.height = Int(CGFloat(display.height) * (NSScreen.main?.backingScaleFactor ?? 2))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 6
        config.showsCursor = true
        if captureSystemAudio {
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
        }

        let url = Recordings.newURL(ext: "mov", prefix: "screen")
        outputURL = url
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height
        ])
        videoInput.expectsMediaDataInRealTime = true
        if writer.canAdd(videoInput) { writer.add(videoInput) }
        self.videoInput = videoInput

        if captureSystemAudio {
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 128_000
            ])
            audioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(audioInput) { writer.add(audioInput) }
            self.audioInput = audioInput
        }

        self.writer = writer

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        self.stream = stream

        writer.startWriting()
        try await stream.startCapture()
        isRecording = true
        Log.info("Screen recording started -> \(url.lastPathComponent)")
    }

    func stop() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        try? await stream?.stopCapture()
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        await writer?.finishWriting()
        let url = outputURL
        Log.info("Screen recording finished -> \(url?.lastPathComponent ?? "nil")")
        stream = nil
        writer = nil
        videoInput = nil
        audioInput = nil
        sessionStarted = false
        return url
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer), let writer = writer else { return }
        guard writer.status == .writing else { return }

        if type == .screen {
            // Only append frames flagged complete.
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let statusRaw = attachments.first?[.status] as? Int,
               let status = SCFrameStatus(rawValue: statusRaw), status != .complete {
                return
            }
            if !sessionStarted {
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                sessionStarted = true
            }
            if videoInput?.isReadyForMoreMediaData == true {
                videoInput?.append(sampleBuffer)
            }
        } else if type == .audio {
            guard sessionStarted else { return }
            if audioInput?.isReadyForMoreMediaData == true {
                audioInput?.append(sampleBuffer)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("SCStream stopped with error: \(error)")
        isRecording = false
    }
}

/// Shared helpers for where recordings are written.
enum Recordings {
    static var directory: URL {
        let dir = AppInfo.supportDirectory.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func newURL(ext: String, prefix: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "\(prefix)_\(formatter.string(from: Date())).\(ext)"
        return directory.appendingPathComponent(name)
    }
}
