import SwiftUI
import AppKit
import ScreenCaptureKit

/// A display the picker can show, with a (lazily captured) preview thumbnail.
final class DisplayCandidate: ObservableObject, Identifiable {
    let id: CGDirectDisplayID
    let index: Int
    let name: String
    let resolution: String
    @Published var thumbnail: NSImage?

    init(id: CGDirectDisplayID, index: Int, name: String, resolution: String) {
        self.id = id
        self.index = index
        self.name = name
        self.resolution = resolution
    }
}

final class ScreenPickerStore: ObservableObject {
    @Published var candidates: [DisplayCandidate] = []
    @Published var needsPermission = false
}

/// Presents a popup with a live preview of every connected display plus an
/// "All Displays" option, while flashing a big number on each physical screen
/// so the user can tell which preview maps to which monitor.
final class ScreenPicker {
    static let shared = ScreenPicker()
    private init() {}

    private var panel: NSPanel?
    private var identifyWindows: [NSWindow] = []
    private let store = ScreenPickerStore()

    func show() {
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        buildCandidates()
        presentIdentifyOverlays()

        let root = ScreenPickerView(store: store,
                                    onRecordDisplay: { [weak self] id in
                                        self?.dismiss()
                                        RecordingCoordinator.shared.toggleScreenRecording(selection: .display(id))
                                    },
                                    onRecordAll: { [weak self] in
                                        self?.dismiss()
                                        RecordingCoordinator.shared.toggleScreenRecording(selection: .all)
                                    },
                                    onGrantPermission: { [weak self] in
                                        self?.dismiss()
                                        Permissions.guideScreenRecording()
                                    },
                                    onCancel: { [weak self] in self?.dismiss() })

        let hosting = NSHostingView(rootView: root)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "Choose a Screen to Record"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        // Must sit ABOVE the full-screen identify overlays (which are at
        // .screenSaver), otherwise the panel is hidden behind them.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel

        captureThumbnails()
    }

    func dismiss() {
        panel?.orderOut(nil)
        identifyWindows.forEach { $0.orderOut(nil) }
        identifyWindows.removeAll()
    }

    // MARK: - Candidates & thumbnails

    private func buildCandidates() {
        store.candidates = RecordingCoordinator.availableDisplays().enumerated().map { idx, d in
            let pixels = "\(Int(d.frame.width * d.scale))×\(Int(d.frame.height * d.scale))"
            let main = d.id == CGMainDisplayID() ? " · Main" : ""
            return DisplayCandidate(id: d.id, index: idx + 1, name: d.name + main, resolution: pixels)
        }
        store.needsPermission = !Permissions.hasScreenRecording()
    }

    private func captureThumbnails() {
        guard Permissions.hasScreenRecording() else { return }
        // Stay on the main actor throughout so there's no Sendable boundary for
        // the (non-Sendable) NSImage / DisplayCandidate values.
        Task { @MainActor in
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            for candidate in store.candidates {
                guard let display = content?.displays.first(where: { $0.displayID == candidate.id }) else { continue }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                let scale = 0.18
                config.width = max(1, Int(Double(display.width) * scale))
                config.height = max(1, Int(Double(display.height) * scale))
                config.showsCursor = false
                if let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                    candidate.thumbnail = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
        }
    }

    // MARK: - Identify overlays (big numbers on each physical screen)

    private func presentIdentifyOverlays() {
        for (idx, screen) in NSScreen.screens.enumerated() {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]

            let label = NSTextField(labelWithString: "\(idx + 1)")
            label.font = .systemFont(ofSize: 180, weight: .bold)
            label.textColor = .white
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false

            let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let badge = NSView()
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            badge.layer?.cornerRadius = 32
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.addSubview(label)
            container.addSubview(badge)

            NSLayoutConstraint.activate([
                badge.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                // Near the top of each screen so the numbers don't sit underneath
                // the centered picker panel.
                badge.topAnchor.constraint(equalTo: container.topAnchor, constant: 120),
                badge.widthAnchor.constraint(equalToConstant: 220),
                badge.heightAnchor.constraint(equalToConstant: 220),
                label.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
            ])

            window.contentView = container
            window.orderFrontRegardless()
            identifyWindows.append(window)
        }
    }
}

// MARK: - SwiftUI

struct ScreenPickerView: View {
    @ObservedObject var store: ScreenPickerStore
    var onRecordDisplay: (CGDirectDisplayID) -> Void
    var onRecordAll: () -> Void
    var onGrantPermission: () -> Void
    var onCancel: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The matching number is shown on each physical screen.")
                .font(.system(size: 12)).foregroundColor(.secondary)
                .padding(.horizontal, 16).padding(.top, 8)

            if store.needsPermission {
                permissionView
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(store.candidates) { candidate in
                            DisplayCard(candidate: candidate) { onRecordDisplay(candidate.id) }
                        }
                    }
                    .padding(16)
                }
            }

            Divider()
            HStack {
                if store.candidates.count > 1 && !store.needsPermission {
                    Button { onRecordAll() } label: {
                        Label("Record All Displays", systemImage: "rectangle.on.rectangle")
                    }
                }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .frame(width: 520, height: 460)
    }

    private var permissionView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "lock.shield").font(.system(size: 40)).foregroundColor(.secondary)
            Text("Screen Recording permission is required to preview and record screens.")
                .multilineTextAlignment(.center).foregroundColor(.secondary)
                .padding(.horizontal, 24)
            Button("Open Privacy Settings", action: onGrantPermission)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DisplayCard: View {
    @ObservedObject var candidate: DisplayCandidate
    var onRecord: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.windowBackgroundColor))
                if let thumb = candidate.thumbnail {
                    Image(nsImage: thumb).resizable().scaledToFit().cornerRadius(8)
                } else {
                    ProgressView()
                }
                VStack {
                    HStack {
                        Text("\(candidate.index)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.accentColor))
                            .padding(6)
                        Spacer()
                    }
                    Spacer()
                }
            }
            .frame(height: 130)

            Text(candidate.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(candidate.resolution).font(.system(size: 10)).foregroundColor(.secondary)
            Button("Record", action: onRecord).buttonStyle(.borderedProminent)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
    }
}
