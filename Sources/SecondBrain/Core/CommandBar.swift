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
        rebuildActions()
        let panel = panel ?? makePanel()
        self.panel = panel

        panel.setFrame(frameForActiveScreen(size: panel.frame.size), display: false)
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
                self?.dismissThen {
                    if RecordingCoordinator.shared.isRecording {
                        RecordingCoordinator.shared.stopIfRecording()
                    } else {
                        RecordingCoordinator.shared.toggleScreenRecording(
                            selection: .display(RecordingCoordinator.displayUnderCursor()))
                    }
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

    private func frameForActiveScreen(size: NSSize) -> NSRect {
        let screen = activeScreen()
        let visible = screen.visibleFrame
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        // Lower third: close to the pointer's usual resting place without
        // covering the middle of whatever the user is looking at.
        let x = visible.midX - width / 2
        let y = visible.minY + visible.height * 0.26
        return NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
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
        HStack(spacing: 6) {
            ForEach(store.actions) { action in
                CommandBarButton(action: action)
            }
        }
        .padding(10)
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
