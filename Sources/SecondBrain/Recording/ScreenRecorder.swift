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
    private let sampleQueue = DispatchQueue(label: "com.dao.secondbrain.screen-sample")

    private(set) var outputURL: URL?
    private(set) var isRecording = false

    /// Fraction of the display captured when following the pointer. Smaller
    /// means a tighter, more zoomed-in frame.
    private static let followZoom: CGFloat = 0.55

    private var followTimer: Timer?
    private var followRect: CGRect?
    private var displayBounds: CGRect = .zero
    private var streamConfig: SCStreamConfiguration?

    func start(display: SCDisplay, captureSystemAudio: Bool, followMouse: Bool = false) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // Use the scale factor of the matching screen so each display records at
        // its own native pixel resolution (important on mixed-DPI multi-monitor setups).
        let screen = NSScreen.screens.first(where: { $0.displayID == display.displayID })
        let scale = screen?.backingScaleFactor ?? 2
        displayBounds = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))

        if followMouse {
            // Capture a fixed-size window of the display and pan it, so the output
            // dimensions stay constant while the crop tracks the pointer.
            let cropSize = CGSize(width: (displayBounds.width * Self.followZoom).rounded(),
                                  height: (displayBounds.height * Self.followZoom).rounded())
            let initial = centredCrop(on: pointerInDisplaySpace(screen: screen), size: cropSize)
            followRect = initial
            config.sourceRect = initial
            config.width = Int(cropSize.width * scale)
            config.height = Int(cropSize.height * scale)
        } else {
            config.width = Int(displayBounds.width * scale)
            config.height = Int(displayBounds.height * scale)
        }
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
        self.streamConfig = config

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        self.stream = stream

        writer.startWriting()
        try await stream.startCapture()
        isRecording = true
        if followMouse { startFollowingPointer(screen: screen) }
        Log.info("Screen recording started -> \(url.lastPathComponent)\(followMouse ? " (following pointer)" : "")")
    }

    func stop() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        await stopFollowingPointer()
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
        streamConfig = nil
        followRect = nil
        sessionStarted = false
        return url
    }

    // MARK: - Follow the pointer

    /// Nudges the capture rect toward the pointer a few times a second. Moving a
    /// fraction of the distance each tick keeps the pan smooth instead of jumpy.
    private func startFollowingPointer(screen: NSScreen?) {
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self, let current = self.followRect, let config = self.streamConfig else { return }
            let target = self.centredCrop(on: self.pointerInDisplaySpace(screen: screen), size: current.size)
            let smoothing: CGFloat = 0.25
            let next = CGRect(x: current.origin.x + (target.origin.x - current.origin.x) * smoothing,
                              y: current.origin.y + (target.origin.y - current.origin.y) * smoothing,
                              width: current.width, height: current.height)
            // Skip sub-pixel updates; they cost a stream reconfigure for nothing.
            guard abs(next.origin.x - current.origin.x) > 1 || abs(next.origin.y - current.origin.y) > 1 else { return }
            self.followRect = next
            config.sourceRect = next
            self.stream?.updateConfiguration(config) { error in
                if let error { Log.error("Follow-pointer update failed: \(error.localizedDescription)") }
            }
        }
        followTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopFollowingPointer() async {
        await MainActor.run {
            followTimer?.invalidate()
            followTimer = nil
        }
    }

    /// Pointer position in the display's own top-left-origin coordinate space,
    /// which is what `sourceRect` expects.
    private func pointerInDisplaySpace(screen: NSScreen?) -> CGPoint {
        let global = NSEvent.mouseLocation
        guard let screen else { return CGPoint(x: displayBounds.midX, y: displayBounds.midY) }
        let frame = screen.frame
        return CGPoint(x: global.x - frame.minX,
                       y: frame.maxY - global.y)
    }

    /// A crop of `size` centred on `point`, clamped inside the display.
    private func centredCrop(on point: CGPoint, size: CGSize) -> CGRect {
        let x = (point.x - size.width / 2).clamped(to: 0...max(0, displayBounds.width - size.width))
        let y = (point.y - size.height / 2).clamped(to: 0...max(0, displayBounds.height - size.height))
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
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

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
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
