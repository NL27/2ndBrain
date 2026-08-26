import SwiftUI
import AppKit

/// One button in the floating command bar.
struct CommandBarAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    /// True while the underlying feature is running, so the button can show a
    /// stop affordance instead of a start one.
    let isRunning: Bool
    let perform: () -> Void
}

/// Which half of the Record drawer is being configured.
enum RecordingTab: String, CaseIterable, Identifiable {
    case screen, audio
    var id: String { rawValue }
    var title: String { self == .screen ? "Screen" : "Audio" }
    var symbol: String { self == .screen ? "display" : "waveform" }
}

@MainActor
final class CommandBarStore: ObservableObject {
    @Published var actions: [CommandBarAction] = []
    /// Shows the recording options drawer beneath the buttons.
    @Published var showingRecordingOptions = false
    @Published var tab: RecordingTab = .screen

    // Mirrors of the persisted settings so the toggles stay live.
    @Published var followMouse = Settings.shared.followMouseWhileRecording {
        didSet { Settings.shared.followMouseWhileRecording = followMouse }
    }
    @Published var captureInput = Settings.shared.showInputOverlay {
        didSet { Settings.shared.showInputOverlay = captureInput }
    }
    @Published var mouseRing = Settings.shared.showMouseRing {
        didSet { Settings.shared.showMouseRing = mouseRing }
    }
    @Published var systemAudio = Settings.shared.captureSystemAudio {
        didSet { Settings.shared.captureSystemAudio = systemAudio }
    }
    @Published var microphone = Settings.shared.captureMicrophone {
        didSet { Settings.shared.captureMicrophone = microphone }
    }
    @Published var showLiveCaptions = Settings.shared.showLiveCaptions {
        didSet { Settings.shared.showLiveCaptions = showLiveCaptions }
    }
    /// Transcribe live (via heed) instead of writing a plain audio recording.
    @Published var liveTranscription = false

    /// Re-reads the settings, in case they were changed from the menu.
    func syncFromSettings() {
        let s = Settings.shared
        if followMouse != s.followMouseWhileRecording { followMouse = s.followMouseWhileRecording }
        if captureInput != s.showInputOverlay { captureInput = s.showInputOverlay }
        if mouseRing != s.showMouseRing { mouseRing = s.showMouseRing }
        if systemAudio != s.captureSystemAudio { systemAudio = s.captureSystemAudio }
        if microphone != s.captureMicrophone { microphone = s.captureMicrophone }
        if showLiveCaptions != s.showLiveCaptions { showLiveCaptions = s.showLiveCaptions }
        liveTranscription = LiveTranscriptionController.shared.isActive
    }

    var startScreenRecording: () -> Void = {}
    var startAudioRecording: () -> Void = {}
    /// Called when the drawer's content changes height so the window can resize.
    var requestRelayout: () -> Void = {}
}

/// A translucent, floating palette of the most-used actions. Opened from the
/// menu or a global hotkey, and dismissed as soon as the user clicks anywhere
/// outside it (or presses Escape).
@MainActor
final class CommandBar: NSObject, NSWindowDelegate {
    static let shared = CommandBar()
    private override init() { super.init() }

    private var panel: CommandBarPanel?
    private let store = CommandBarStore()
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var stateObservers: [NSObjectProtocol] = []

    // MARK: - Presentation

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        store.syncFromSettings()
        store.showingRecordingOptions = false
        rebuildActions()
        let panel = panel ?? makePanel()
        self.panel = panel

        panel.layoutIfNeeded()
        positionPanel(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            // Deliberately below 1 so the bar stays see-through over content.
            panel.animator().alphaValue = 0.96
        }

        startMonitoring()
    }

    func hide() {
        stopMonitoring()
        store.showingRecordingOptions = false
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    /// Dismisses the bar, then runs the action on the next tick so the palette is
    /// never included in a screenshot and never fights the panel it opens.
    private func dismissThen(_ action: @escaping () -> Void) {
        hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { action() }
    }

    // MARK: - Actions

    private func rebuildActions() {
        let recorder = RecordingCoordinator.shared
        let liveRunning = LiveTranscriptionController.shared.isActive
        let busy = recorder.isRecording || liveRunning

        store.actions = [
            CommandBarAction(id: "capture", title: "Capture Area",
                             symbol: "camera.viewfinder", isRunning: false) { [weak self] in
                self?.dismissThen { ScreenshotManager.shared.captureRegionToClipboard() }
            },
            CommandBarAction(id: "ocr", title: "OCR",
                             symbol: "text.viewfinder", isRunning: false) { [weak self] in
                self?.dismissThen { OCRManager.shared.captureRegionAndCopyText() }
            },
            CommandBarAction(id: "record", title: busy ? "Stop" : "Record",
                             symbol: busy ? "stop.circle.fill" : "record.circle",
                             isRunning: busy) { [weak self] in
                guard let self else { return }
                if busy {
                    self.dismissThen {
                        RecordingCoordinator.shared.stopIfRecording()
                        if LiveTranscriptionController.shared.isActive {
                            LiveTranscriptionController.shared.stop()
                        }
                    }
                } else {
                    // Reveal the options drawer instead of starting immediately.
                    self.store.syncFromSettings()
                    self.store.showingRecordingOptions.toggle()
                    self.relayoutAfterDrawerChange()
                }
            },
            CommandBarAction(id: "history", title: "History",
                             symbol: "doc.on.clipboard", isRunning: false) { [weak self] in
                self?.dismissThen { ClipboardHistoryController.shared.toggle(relativeTo: nil) }
            }
        ]

        store.startScreenRecording = { [weak self] in
            guard let self, let panel = self.panel else { return }
            // Record the screen this bar is sitting on, decided before it hides.
            let displayID = RecordingCoordinator.display(containing: panel)
            self.dismissThen {
                RecordingCoordinator.shared.toggleScreenRecording(selection: .display(displayID))
            }
        }

        store.startAudioRecording = { [weak self] in
            guard let self else { return }
            let live = self.store.liveTranscription
            self.dismissThen {
                // heed needs exclusive use of the microphone, so live
                // transcription replaces the plain recorder rather than joining it.
                if live {
                    LiveTranscriptionController.shared.start()
                } else {
                    RecordingCoordinator.shared.toggleAudioRecording()
                }
            }
        }
    }

    /// The drawer changes the panel's height, so resize around the top edge —
    /// otherwise the bar appears to jump when it expands.
    private func relayoutAfterDrawerChange() {
        guard let panel else { return }
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        var frame = NSRect(x: topLeft.x, y: topLeft.y - size.height,
                           width: size.width, height: size.height)
        frame = clamp(frame, to: screenForPanel(panel))
        panel.setFrame(frame, display: true, animate: false)
    }

    // MARK: - Window

    private func makePanel() -> CommandBarPanel {
        let root = CommandBarView(store: store)
        let hosting = NSHostingView(rootView: root)
        hosting.setFrameSize(hosting.fittingSize)

        let panel = CommandBarPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.hide() }
        store.requestRelayout = { [weak self] in self?.relayoutAfterDrawerChange() }
        // Draggable from any empty area of the bar, plus the explicit grip.
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.contentView = hosting

        observeFeatureState()
        return panel
    }

    /// Keeps the buttons in sync (start/stop labels) while the bar is open.
    private func observeFeatureState() {
        guard stateObservers.isEmpty else { return }
        for name in [RecordingCoordinator.stateChanged, LiveTranscriptionController.stateChanged] {
            let observer = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.panel?.isVisible == true else { return }
                    self.rebuildActions()
                }
            }
            stateObservers.append(observer)
        }
    }

    /// Always opens in the same spot — centred in the lower third of the screen
    /// holding the pointer. It can still be dragged while it's open; the next
    /// time it appears it returns here.
    private func positionPanel(_ panel: CommandBarPanel) {
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        let screen = activeScreen()
        let visible = screen.visibleFrame
        let frame = NSRect(x: (visible.midX - size.width / 2).rounded(),
                           y: (visible.minY + visible.height * 0.26).rounded(),
                           width: size.width, height: size.height)
        panel.setFrame(clamp(frame, to: screen), display: false)
    }

    private func clamp(_ frame: NSRect, to screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        var result = frame
        result.origin.x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
        result.origin.y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
        return result
    }

    private func screenForPanel(_ panel: NSWindow) -> NSScreen {
        panel.screen ?? activeScreen()
    }

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    // MARK: - Dismiss on outside click

    private func startMonitoring() {
        stopMonitoring()
        // Clicks in other apps / on the desktop.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideIfClickOutside() }
        }
        // Clicks elsewhere inside this app (e.g. another 2ⁿᵈ Brain panel).
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.window !== self?.panel { self?.hideIfClickOutside() }
            }
            return event
        }
    }

    private func stopMonitoring() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        globalClickMonitor = nil
        localClickMonitor = nil
    }

    private func hideIfClickOutside() {
        guard let panel, panel.isVisible else { return }
        if !NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) {
            hide()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

/// Borderless panel that can still take key events, so Escape closes the bar
/// and the buttons respond on the first click.
final class CommandBarPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: - SwiftUI

struct CommandBarView: View {
    @ObservedObject var store: CommandBarStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                WindowDragHandle()
                    .frame(width: 16, height: 62)
                ForEach(store.actions) { action in
                    CommandBarButton(action: action)
                }
            }
            .padding(10)

            if store.showingRecordingOptions {
                Divider().padding(.horizontal, 10)
                RecordingOptionsView(store: store)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                    .onChange(of: store.tab) { store.requestRelayout() }
                    .onChange(of: store.captureInput) { store.requestRelayout() }
                    .onChange(of: store.liveTranscription) { store.requestRelayout() }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
        )
        .padding(6)
        .fixedSize()
    }
}

/// The options drawer that opens beneath the bar when Record is clicked. Screen
/// and Audio each own their own set of options.
private struct RecordingOptionsView: View {
    @ObservedObject var store: CommandBarStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $store.tab) {
                ForEach(RecordingTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch store.tab {
            case .screen: screenOptions
            case .audio: audioOptions
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
        .frame(width: 320, alignment: .leading)
    }

    private var screenOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Follow the mouse (zoomed pan)", isOn: $store.followMouse)
            Toggle("Show mouse clicks & keystrokes", isOn: $store.captureInput)
            Toggle("Colour ring around the mouse", isOn: $store.mouseRing)

            if store.captureInput {
                Text(Permissions.hasAccessibility()
                     ? "Clicks and keys are also written to a .input.jsonl log next to the video."
                     : "Keystrokes need Accessibility — clicks only until it's granted.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Records the screen this bar is on.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Button(action: store.startScreenRecording) {
                Label("Start Screen Recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 2)
        }
    }

    private var audioOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Microphone", isOn: $store.microphone)
            Toggle("System audio", isOn: $store.systemAudio)
            Toggle("Live transcription", isOn: $store.liveTranscription)

            if store.liveTranscription {
                Toggle("Show captions on screen", isOn: $store.showLiveCaptions)
                    .padding(.leading, 18)
                Text("Live transcription uses heed and takes the microphone for itself.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: store.startAudioRecording) {
                Label(store.liveTranscription ? "Start Live Transcription" : "Start Audio Recording",
                      systemImage: store.liveTranscription ? "waveform" : "mic")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 2)
        }
    }
}

/// Transparent strip that drags the whole window, so the bar can be repositioned
/// without relying on hitting empty background between buttons.
private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.withAlphaComponent(0.5).setFill()
            let dot: CGFloat = 3
            let spacing: CGFloat = 6
            let rows = 4
            let totalHeight = CGFloat(rows) * dot + CGFloat(rows - 1) * (spacing - dot)
            var y = bounds.midY - totalHeight / 2
            for _ in 0..<rows {
                for column in 0..<2 {
                    let rect = NSRect(x: bounds.midX - spacing / 2 + CGFloat(column) * spacing,
                                      y: y, width: dot, height: dot)
                    NSBezierPath(ovalIn: rect).fill()
                }
                y += spacing
            }
        }
    }
}

private struct CommandBarButton: View {
    let action: CommandBarAction
    @State private var hovering = false

    var body: some View {
        Button(action: action.perform) {
            VStack(spacing: 6) {
                Image(systemName: action.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(action.isRunning ? Color.red : Color.primary)
                    .frame(height: 24)
                Text(action.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(width: 84, height: 62)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.12 : 0.04))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(action.title)
    }
}
