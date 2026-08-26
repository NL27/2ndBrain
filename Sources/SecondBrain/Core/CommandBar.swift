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

@MainActor
final class CommandBarStore: ObservableObject {
    @Published var actions: [CommandBarAction] = []
    /// Shows the recording options drawer beneath the buttons.
    @Published var showingRecordingOptions = false

    // Mirrors of the persisted settings so the toggles stay live.
    @Published var followMouse = Settings.shared.followMouseWhileRecording {
        didSet { Settings.shared.followMouseWhileRecording = followMouse }
    }
    @Published var captureInput = Settings.shared.showInputOverlay {
        didSet { Settings.shared.showInputOverlay = captureInput }
    }
    @Published var systemAudio = Settings.shared.captureSystemAudio {
        didSet { Settings.shared.captureSystemAudio = systemAudio }
    }
    @Published var microphone = Settings.shared.captureMicrophone {
        didSet { Settings.shared.captureMicrophone = microphone }
    }

    /// Re-reads the settings, in case they were changed from the menu.
    func syncFromSettings() {
        let s = Settings.shared
        if followMouse != s.followMouseWhileRecording { followMouse = s.followMouseWhileRecording }
        if captureInput != s.showInputOverlay { captureInput = s.showInputOverlay }
        if systemAudio != s.captureSystemAudio { systemAudio = s.captureSystemAudio }
        if microphone != s.captureMicrophone { microphone = s.captureMicrophone }
    }

    var startRecording: () -> Void = {}
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
    /// Where the user last dragged the bar, so it reopens where they left it.
    private var userOrigin: NSPoint?

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
        // Remember where it was dragged to before it goes away.
        userOrigin = panel.frame.origin
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
        let screenRecording = recorder.isRecording && recorder.mode == .screen
        let audioRecording = recorder.isRecording && recorder.mode == .audioOnly
        let liveRunning = LiveTranscriptionController.shared.isActive

        store.actions = [
            CommandBarAction(id: "capture", title: "Capture Area",
                             symbol: "camera.viewfinder", isRunning: false) { [weak self] in
                self?.dismissThen { ScreenshotManager.shared.captureRegionToClipboard() }
            },
            CommandBarAction(id: "ocr", title: "OCR",
                             symbol: "text.viewfinder", isRunning: false) { [weak self] in
                self?.dismissThen { OCRManager.shared.captureRegionAndCopyText() }
            },
            CommandBarAction(id: "screen", title: screenRecording ? "Stop Screen" : "Record Screen",
                             symbol: screenRecording ? "stop.circle.fill" : "record.circle",
                             isRunning: screenRecording) { [weak self] in
                guard let self else { return }
                if RecordingCoordinator.shared.isRecording {
                    self.dismissThen { RecordingCoordinator.shared.stopIfRecording() }
                } else {
                    // Reveal the options drawer instead of starting immediately.
                    self.store.syncFromSettings()
                    self.store.showingRecordingOptions.toggle()
                    self.relayoutAfterDrawerChange()
                }
            },
            CommandBarAction(id: "audio", title: audioRecording ? "Stop Audio" : "Record Audio",
                             symbol: audioRecording ? "stop.circle.fill" : "mic",
                             isRunning: audioRecording) { [weak self] in
                self?.dismissThen { RecordingCoordinator.shared.toggleAudioRecording() }
            },
            CommandBarAction(id: "live", title: liveRunning ? "Stop Live" : "Live Transcription",
                             symbol: "waveform", isRunning: liveRunning) { [weak self] in
                self?.dismissThen { LiveTranscriptionController.shared.toggle() }
            },
            CommandBarAction(id: "history", title: "History",
                             symbol: "doc.on.clipboard", isRunning: false) { [weak self] in
                self?.dismissThen { ClipboardHistoryController.shared.toggle(relativeTo: nil) }
            }
        ]

        store.startRecording = { [weak self] in
            guard let self, let panel = self.panel else { return }
            // Record the screen this bar is sitting on, decided before it hides.
            let displayID = RecordingCoordinator.display(containing: panel)
            self.dismissThen {
                RecordingCoordinator.shared.toggleScreenRecording(selection: .display(displayID))
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

    /// Reopens where the user last dragged it, otherwise centres it in the lower
    /// third of the screen holding the pointer.
    private func positionPanel(_ panel: CommandBarPanel) {
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        var frame: NSRect
        if let origin = userOrigin {
            frame = NSRect(origin: origin, size: size)
        } else {
            let visible = activeScreen().visibleFrame
            frame = NSRect(x: (visible.midX - size.width / 2).rounded(),
                           y: (visible.minY + visible.height * 0.26).rounded(),
                           width: size.width, height: size.height)
        }
        // A remembered position can end up off-screen if displays changed.
        let host = NSScreen.screens.first { $0.frame.intersects(frame) } ?? activeScreen()
        panel.setFrame(clamp(frame, to: host), display: false)
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

    func windowDidMove(_ notification: Notification) {
        guard let panel, panel.isVisible else { return }
        userOrigin = panel.frame.origin
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

/// The options drawer that opens beneath the bar when Record Screen is clicked.
private struct RecordingOptionsView: View {
    @ObservedObject var store: CommandBarStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Screen Recording")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Toggle("Follow the mouse (zoomed pan)", isOn: $store.followMouse)
            Toggle("Show mouse clicks & keystrokes", isOn: $store.captureInput)
            Toggle("Record system audio", isOn: $store.systemAudio)
            Toggle("Record microphone", isOn: $store.microphone)

            if store.captureInput && !Permissions.hasAccessibility() {
                Text("Keystrokes need Accessibility — clicks only until it's granted.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Text("Records the screen this bar is on.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Button(action: store.startRecording) {
                Label("Start Recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 2)
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
        .frame(width: 300, alignment: .leading)
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
