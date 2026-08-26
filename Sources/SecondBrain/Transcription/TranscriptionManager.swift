import AVFoundation
import AppKit

/// Supported local transcription engines.
enum TranscriptionBackend: String, CaseIterable {
    case whisperCpp   // whisper.cpp — fastest native, Metal accelerated
    case mlxWhisper   // mlx-whisper — Apple Silicon MLX backend
    case tiron        // Trelis Tiron — multi-speaker meetings, transcript + speakers in one pass

    var displayName: String {
        switch self {
        case .whisperCpp: return "whisper.cpp"
        case .mlxWhisper: return "mlx-whisper"
        case .tiron: return "Tiron (multi-speaker meetings)"
        }
    }

    /// Whether the engine labels who said what, without a separate diarizer.
    var attributesSpeakers: Bool { self == .tiron }

    /// Tiron ships its own checkpoint, so the ggml model setting doesn't apply.
    var usesWhisperModel: Bool { self != .tiron }
}

/// Runs local transcription (and optional speaker diarization) on a recording.
/// Heavy lifting is delegated to an installed CLI engine; this class converts
/// audio to 16 kHz mono WAV, invokes the engine, and surfaces the transcript.
final class TranscriptionManager: Sendable {
    static let shared = TranscriptionManager()
    private init() {}

    private let queue = DispatchQueue(label: "com.dao.secondbrain.transcription", qos: .userInitiated)

    /// Whether the engine's CLI is installed, so callers can offer it or not.
    func isInstalled(_ backend: TranscriptionBackend) -> Bool {
        switch backend {
        case .whisperCpp: return locate(["whisper-cli", "whisper-cpp", "main"]) != nil
        case .mlxWhisper: return locate(["mlx_whisper"]) != nil
        case .tiron: return locate(["tiron"]) != nil
        }
    }

    /// Transcribes a file with one specific engine and hands back the text,
    /// leaving the file's own sidecar transcript alone. Used to re-examine a live
    /// session's audio with Tiron for who-said-what.
    func transcript(for url: URL, using backend: TranscriptionBackend) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let scratch = FileManager.default.temporaryDirectory
                    .appendingPathComponent("secondbrain-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: scratch) }
                do {
                    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                    let wav = try self.convertToWav(url, in: scratch)
                    continuation.resume(returning: try self.runBackend(on: wav, backend: backend))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func transcribe(url: URL) {
        queue.async {
            do {
                Log.info("Transcription started for \(url.lastPathComponent)")
                self.notify("Transcribing \(url.lastPathComponent)…")
                let wav = try self.convertToWav(url)
                let transcript = try self.runBackend(on: wav, backend: Settings.shared.whisperBackend)
                let outURL = url.deletingPathExtension().appendingPathExtension("txt")
                try transcript.write(to: outURL, atomically: true, encoding: .utf8)
                VaultWriter.saveTranscript(transcript, for: url)
                Log.info("Transcript written -> \(outURL.lastPathComponent)")
                self.notify("Transcript ready: \(outURL.lastPathComponent)")
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([outURL]) }
            } catch {
                Log.error("Transcription failed: \(error.localizedDescription)")
                self.notify("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Backend invocation

    private func runBackend(on wav: URL, backend: TranscriptionBackend) throws -> String {
        let model = Settings.shared.whisperModel

        switch backend {
        case .whisperCpp:
            return try runWhisperCpp(wav: wav, model: model)
        case .mlxWhisper:
            return try runMlxWhisper(wav: wav, model: model)
        case .tiron:
            return try runTiron(wav: wav)
        }
    }

    private func runWhisperCpp(wav: URL, model: String) throws -> String {
        guard let exe = locate(["whisper-cli", "whisper-cpp", "main"]) else {
            throw err("whisper.cpp not found. Run scripts/install.sh to install it.")
        }
        let modelPath = try resolveWhisperModel(model)
        let out = wav.deletingPathExtension()
        let args = ["-m", modelPath, "-f", wav.path, "-otxt", "-of", out.path, "-np"]
        _ = try run(exe, args)
        let txt = out.appendingPathExtension("txt")
        return (try? String(contentsOf: txt, encoding: .utf8)) ?? "(no text produced)"
    }

    /// Tiron transcribes and attributes speakers in one decoding pass, then links
    /// window-local speakers across the whole meeting — so no separate diarizer.
    private func runTiron(wav: URL) throws -> String {
        guard let exe = locate(["tiron"]) else {
            throw err("Tiron not found. Open 2ⁿᵈ Brain ▸ Setup to install it.")
        }
        let out = wav.deletingPathExtension().appendingPathExtension("txt")
        var args = [wav.path, "--format", "text", "--output", out.path,
                    "--language", Settings.shared.transcriptionLanguage]
        let maxSpeakers = Settings.shared.tironMaxSpeakers
        if maxSpeakers > 0 { args += ["--max-speakers", String(maxSpeakers)] }

        notify("Transcribing with Tiron…")
        _ = try run(exe, args)
        return (try? String(contentsOf: out, encoding: .utf8)) ?? "(no text produced)"
    }

    private func runMlxWhisper(wav: URL, model: String) throws -> String {
        guard let exe = locate(["mlx_whisper"]) else {
            throw err("mlx-whisper not found. Run scripts/install.sh to install it.")
        }
        let args = [wav.path, "--model", "mlx-community/whisper-\(model)", "--output-dir",
                    wav.deletingLastPathComponent().path, "--output-format", "txt"]
        _ = try run(exe, args)
        let txt = wav.deletingPathExtension().appendingPathExtension("txt")
        return (try? String(contentsOf: txt, encoding: .utf8)) ?? "(no text produced)"
    }

    // MARK: - Audio conversion (-> 16 kHz mono WAV)

    /// Converts to the 16 kHz mono WAV every engine expects. `directory` keeps the
    /// intermediate out of folders we don't own (heed's recordings, say).
    func convertToWav(_ input: URL, in directory: URL? = nil) throws -> URL {
        let asset = AVURLAsset(url: input)
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw err("Could not read audio from \(input.lastPathComponent)")
        }
        // Synchronously load the audio track.
        let tracks = AVAsset.audioTracks(asset)
        guard let track = tracks.first else { throw err("No audio track in recording") }

        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        reader.add(output)

        let base = directory?.appendingPathComponent(input.deletingPathExtension().lastPathComponent)
            ?? input.deletingPathExtension()
        let outURL = base.appendingPathExtension("16k.wav")
        try? FileManager.default.removeItem(at: outURL)
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .wav)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: readerSettings)
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        reader.startReading()

        let sem = DispatchSemaphore(value: 0)
        let pump = DispatchQueue(label: "com.dao.secondbrain.wav-pump")
        writerInput.requestMediaDataWhenReady(on: pump) {
            while writerInput.isReadyForMoreMediaData {
                if let buffer = output.copyNextSampleBuffer() {
                    writerInput.append(buffer)
                } else {
                    writerInput.markAsFinished()
                    sem.signal()
                    break
                }
            }
        }
        sem.wait()
        let finishSem = DispatchSemaphore(value: 0)
        writer.finishWriting { finishSem.signal() }
        finishSem.wait()

        if reader.status == .failed { throw err("Audio conversion failed: \(reader.error?.localizedDescription ?? "")") }
        return outURL
    }

    // MARK: - Helpers

    /// Returns the path to the requested ggml model, falling back to any model
    /// that is actually installed so a profile/model mismatch doesn't fail hard.
    private func resolveWhisperModel(_ model: String) throws -> String {
        let dir = AppInfo.supportDirectory.appendingPathComponent("models", isDirectory: true)
        let preferred = dir.appendingPathComponent("ggml-\(model).bin")
        if FileManager.default.fileExists(atPath: preferred.path) { return preferred.path }

        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
           let fallback = files.first(where: { $0.lastPathComponent.hasPrefix("ggml-") && $0.pathExtension == "bin" }) {
            Log.info("Whisper model '\(model)' not installed; using \(fallback.lastPathComponent)")
            return fallback.path
        }
        throw err("Whisper model 'ggml-\(model).bin' not found. Run: scripts/install.sh --with-whisper --model \(model)")
    }

    /// Searches common locations + PATH for an executable.
    private func locate(_ names: [String]) -> URL? {
        var dirs = [
            AppInfo.supportDirectory.appendingPathComponent("bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            // pipx / uv tool installs (tiron, mlx-whisper) land here, and a GUI
            // app launched from Finder doesn't inherit a login shell's PATH.
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        for name in names {
            for dir in dirs {
                let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    @discardableResult
    private func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw err("\(executable.lastPathComponent) exited \(process.terminationStatus): \(out)")
        }
        return out
    }

    private func err(_ message: String) -> NSError {
        NSError(domain: "SecondBrain.Transcription", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func notify(_ message: String) {
        Log.info(message)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .init("SecondBrainStatus"), object: message)
        }
    }
}

private extension AVAsset {
    /// Synchronously fetch audio tracks (acceptable on the transcription queue).
    static func audioTracks(_ asset: AVAsset) -> [AVAssetTrack] {
        if #available(macOS 13.0, *) {
            let sem = DispatchSemaphore(value: 0)
            var result: [AVAssetTrack] = []
            Task {
                result = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
                sem.signal()
            }
            sem.wait()
            return result
        } else {
            return asset.tracks(withMediaType: .audio)
        }
    }
}
