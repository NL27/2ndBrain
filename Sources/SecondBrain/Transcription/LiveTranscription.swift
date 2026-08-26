import SwiftUI
import AppKit

/// Live transcript state, fed by heed's SSE stream.
@MainActor
final class LiveTranscriptStore: ObservableObject {
    struct Line: Identifiable {
        let id: String
        var speaker: String
        var channel: String
        var text: String
    }

    @Published fileprivate(set) var lines: [Line] = []
    @Published fileprivate(set) var status: String = ""
    @Published fileprivate(set) var isRunning = false
    /// A finished session whose audio is still around, so Tiron can be asked to
    /// sort out the speakers even if we judged it single-voice.
    @Published fileprivate(set) var canLabelSpeakers = false

    var transcript: String {
        lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    fileprivate func reset() {
        lines = []
        status = ""
        canLabelSpeakers = false
    }

    fileprivate func apply(_ update: HeedClient.LiveUpdate) {
        switch update {
        case .append(let line):
            lines.append(Line(id: UUID().uuidString, speaker: line.speaker,
                              channel: line.channel, text: line.text))
        case .replace(let line):
            // Full mode re-decodes the whole take each tick, so it owns one line.
            upsert(Line(id: "live-full", speaker: line.speaker, channel: line.channel, text: line.text))
        case .upsert(let line):
            upsert(Line(id: "turn-\(line.id ?? lines.count)", speaker: line.speaker,
                        channel: line.channel, text: line.text))
        }
    }

    private func upsert(_ line: Line) {
        if let index = lines.firstIndex(where: { $0.id == line.id }) {
            lines[index] = line
        } else {
            lines.append(line)
        }
    }
}

/// Full-width bar showing the live transcript as it streams in.
struct LiveTranscriptView: View {
    @ObservedObject var store: LiveTranscriptStore
    var onStop: () -> Void
    var onCopy: () -> Void
    var onOpenHeed: () -> Void
    var onLabelSpeakers: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: store.isRunning ? "waveform" : "text.quote")
                .foregroundColor(store.isRunning ? .red : .secondary)
                .symbolEffect(.variableColor, isActive: store.isRunning)
            Text("Live Transcription").font(.system(size: 13, weight: .semibold))
            Text("heed · speakers").font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))

            if !store.status.isEmpty {
                Text(store.status).font(.system(size: 11)).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Spacer()

            Button(action: onCopy) { Label("Copy", systemImage: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy the transcript")
            if store.canLabelSpeakers {
                Button(action: onLabelSpeakers) { Label("Label Speakers", systemImage: "person.2.wave.2") }
                    .buttonStyle(.borderless)
                    .help("Run Tiron over this session's audio to work out who said what")
            }
            Button(action: onOpenHeed) { Label("Notes", systemImage: "arrow.up.forward.app") }
                .buttonStyle(.borderless).help("Open this session in heed")
            if store.isRunning {
                Button(action: onStop) { Label("Stop", systemImage: "stop.circle.fill") }
                    .buttonStyle(.borderless).help("Stop and save the transcript")
            }
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                .buttonStyle(.borderless).help("Close")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if store.lines.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "ear").font(.system(size: 26)).foregroundColor(.secondary)
                Text(store.isRunning ? "Listening…" : "No speech captured")
                    .foregroundColor(.secondary).font(.system(size: 12))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.lines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: line.channel == "sys" ? "speaker.wave.2.fill" : "mic.fill")
                                    .font(.system(size: 10)).foregroundColor(.secondary)
                                    .frame(width: 14)
                                Text(line.speaker)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.accentColor)
                                Text(line.text).font(.system(size: 13)).textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .id(line.id)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: store.lines.count) {
                    if let last = store.lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
    }
}

/// Drives a live transcription session: asks heed to record, streams its text
/// into a floating bar, and saves heed's higher-accuracy final transcript
/// alongside 2ⁿᵈ Brain's own recordings when the session stops.
@MainActor
final class LiveTranscriptionController: NSObject {
    static let shared = LiveTranscriptionController()
    static let stateChanged = Notification.Name("LiveTranscriptionStateChanged")

    private let store = LiveTranscriptStore()
    private var panel: NSPanel?
    private var streamTask: Task<Void, Never>?
    private var language = "auto"
    private let barHeight: CGFloat = 220
    /// The last finished session, kept so its speakers can be labelled on demand.
    private var lastAudio: URL?
    private var lastTranscript: URL?
    private var isRefining = false

    private(set) var isActive = false

    func toggle() {
        if isActive { stop() } else { start() }
    }

    func start() {
        guard !isActive else { return }
        // heed records the microphone itself, which it can't do while our own
        // recorder holds it.
        guard !RecordingCoordinator.shared.isRecording else {
            showAlert(title: "Already Recording",
                      message: "2ⁿᵈ Brain is recording right now, and live transcription needs the microphone. Stop the recording first.")
            return
        }
        Task { await beginSession() }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        streamTask?.cancel()
        streamTask = nil
        store.isRunning = false
        store.status = "Finishing the accurate pass in heed…"
        NotificationCenter.default.post(name: Self.stateChanged, object: nil)

        Task {
            do {
                let result = try await HeedClient.shared.stopRecording(language: language)
                let url = try writeTranscript(result)
                lastTranscript = url
                lastAudio = result.audioPath.map { URL(fileURLWithPath: $0) }
                store.status = "Saved \(url.lastPathComponent)"
                HUD.shared.show("Transcript saved", symbol: "text.quote")
                NSWorkspace.shared.activateFileViewerSelecting([url])
                store.canLabelSpeakers = canRunTiron

                // Heed already streams speaker labels live. Tiron is the stronger
                // pass for overlapping voices on one channel — run it when we can
                // tell there were several people, otherwise ask.
                if canRunTiron {
                    if hasSeveralVoices(result) {
                        if Settings.shared.refineLiveWithTiron { await labelSpeakers() }
                    } else if askIfMultiSpeaker() {
                        await labelSpeakers()
                    }
                }
            } catch {
                store.status = "Couldn't save the transcript: \(error.localizedDescription)"
                Log.error("heed stop failed: \(error.localizedDescription)")
            }
        }
    }

    private func askIfMultiSpeaker() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Did more than one person speak?"
        alert.informativeText = """
        Live captions already named speakers from the microphone and system-audio \
        channels. Tiron can re-examine the same recording and often does better when \
        several people shared one channel or talked over each other.
        """
        alert.addButton(withTitle: "Yes — Refine with Tiron")
        alert.addButton(withTitle: "No — Keep This Transcript")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Speakers

    private var canRunTiron: Bool {
        guard let lastAudio, FileManager.default.fileExists(atPath: lastAudio.path) else { return false }
        return TranscriptionManager.shared.isInstalled(.tiron)
    }

    /// heed labels voices live from the microphone and system-audio channels;
    /// Tiron then re-examines the same recording, where it is much better at
    /// telling apart people sharing one channel. Running both is what makes a
    /// live session end up with every speaker named.
    private func hasSeveralVoices(_ result: HeedClient.StopResult) -> Bool {
        let speakers = Set(result.turns.map(\.speaker)).subtracting(["", "???"])
        let channels = Set(result.turns.map(\.channel)).subtracting([""])
        if speakers.count >= 2 || channels.count >= 2 { return true }
        // No finalized turns to judge by — fall back to what was on screen.
        return Set(store.lines.map(\.speaker)).subtracting(["", "???"]).count >= 2
    }

    func labelSpeakers() async {
        guard !isRefining, canRunTiron, let audio = lastAudio else { return }
        isRefining = true
        defer { isRefining = false }

        store.status = "Working out who spoke, with Tiron…"
        do {
            let text = try await TranscriptionManager.shared.transcript(for: audio, using: .tiron)
            let base = lastTranscript?.deletingPathExtension()
                ?? Recordings.newURL(ext: "txt", prefix: "live").deletingPathExtension()
            let url = base.appendingPathExtension("speakers.txt")
            try text.write(to: url, atomically: true, encoding: .utf8)
            store.status = "Saved \(url.lastPathComponent)"
            HUD.shared.show("Speakers labelled", symbol: "person.2.wave.2")
            NSWorkspace.shared.activateFileViewerSelecting([url])
            Log.info("Tiron speaker pass written -> \(url.lastPathComponent)")
        } catch {
            store.status = "Tiron couldn't label the speakers: \(error.localizedDescription)"
            Log.error("Tiron speaker pass failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Session

    private func beginSession() async {
        // Show the bar first: starting heed loads its models, which is worth
        // watching rather than staring at nothing after the hotkey.
        store.reset()
        store.status = "Checking heed…"
        present()

        do {
            try await HeedSupervisor.shared.ensureRunning { [weak self] status in
                self?.store.status = status
            }
        } catch {
            panel?.orderOut(nil)
            presentHeedUnavailable(error)
            return
        }

        let health = try? await HeedClient.shared.health()
        language = HeedClient.shared.resolveLanguage(Settings.shared.transcriptionLanguage, health: health)

        do {
            guard try await HeedClient.shared.startRecording() else {
                panel?.orderOut(nil)
                showAlert(title: "heed Needs Screen Recording",
                          message: "heed opened System Settings → Privacy & Security → Screen Recording. Enable it for heed, then start live transcription again.")
                return
            }
        } catch {
            panel?.orderOut(nil)
            showAlert(title: "Couldn't Start Live Transcription", message: error.localizedDescription)
            return
        }

        isActive = true
        store.isRunning = true
        store.status = language == "auto" ? "Listening — detecting language" : "Listening — \(language)"
        present()
        NotificationCenter.default.post(name: Self.stateChanged, object: nil)
        Log.info("Live transcription started (heed, language=\(language))")

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in HeedClient.shared.liveEvents(language: self.language) {
                    switch event {
                    case .update(let update):
                        self.store.apply(update)
                    case .stopped:
                        return
                    case .failed(let message):
                        self.store.status = message
                        Log.error("heed live transcription: \(message)")
                        return
                    }
                }
            } catch {
                self.store.status = error.localizedDescription
                Log.error("heed live stream failed: \(error.localizedDescription)")
            }
        }
    }

    /// Prefers heed's finalized turns (real timestamps, clustered voices) and
    /// falls back to what was shown live if the final pass returned nothing.
    private func writeTranscript(_ result: HeedClient.StopResult) throws -> URL {
        let body = result.turns.isEmpty
            ? store.transcript
            : result.turns.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        var contents = body
        if let audio = result.audioPath {
            contents = "Audio: \(audio)\n\n" + body
        }
        let url = Recordings.newURL(ext: "txt", prefix: "live")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        Log.info("Live transcript written -> \(url.lastPathComponent)")
        return url
    }

    // MARK: - Panel

    private func present() {
        // Captions can be turned off entirely; the transcript is still recorded
        // and saved, it just runs without anything on screen.
        guard Settings.shared.showLiveCaptions else {
            panel?.orderOut(nil)
            return
        }
        let screen = activeScreen()
        let frame = NSRect(x: screen.frame.minX, y: screen.visibleFrame.minY,
                           width: screen.frame.width, height: barHeight)

        if let panel {
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            return
        }

        let root = LiveTranscriptView(store: store,
                                      onStop: { [weak self] in self?.stop() },
                                      onCopy: { [weak self] in self?.copyTranscript() },
                                      onOpenHeed: { [weak self] in self?.openHeed() },
                                      onLabelSpeakers: { [weak self] in Task { await self?.labelSpeakers() } },
                                      onClose: { [weak self] in self?.close() })

        // Non-activating so captions can sit over a call without stealing focus.
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: root)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func close() {
        if isActive { stop() }
        panel?.orderOut(nil)
    }

    private func copyTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(store.transcript, forType: .string)
        HUD.shared.show("Transcript copied", symbol: "doc.on.doc")
    }

    private func openHeed() {
        if let url = URL(string: Settings.shared.heedBaseURL) { NSWorkspace.shared.open(url) }
    }

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    // MARK: - Alerts

    /// Live transcription runs on the local heed engine, which setup installs.
    /// If it isn't there, send the user to setup rather than to a terminal.
    private func presentHeedUnavailable(_ error: Error) {
        let missing = (error as? HeedSupervisor.Failure) != nil && !HeedSupervisor.shared.isInstalled
        let alert = NSAlert()
        alert.messageText = missing ? "Live Transcription Isn't Installed Yet" : "Couldn't Start Live Transcription"
        alert.informativeText = missing
            ? """
              Live transcription runs on heed, a local engine that 2ⁿᵈ Brain installs \
              for you. Setup downloads it once, along with its Neural Engine models — \
              after that it starts by itself and needs no network.
              """
            : "\(error.localizedDescription)\n\nOpen setup to check the local engines."
        alert.addButton(withTitle: missing ? "Install Now…" : "Open Setup…")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SetupWindowController.shared.present()
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
