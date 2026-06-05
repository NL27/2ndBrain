import SwiftUI
import AppKit

/// Observable wrapper that bridges ClipboardManager into SwiftUI.
final class ClipboardStore: ObservableObject {
    @Published var items: [ClipboardItem] = []
    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: ClipboardManager.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() { items = ClipboardManager.shared.items }
}

/// Full-width bar (Setapp "Paste"-style) that docks at the bottom of the screen
/// and scrolls clipboard items horizontally.
struct ClipboardHistoryView: View {
    @ObservedObject var store: ClipboardStore
    @State private var query: String = ""
    var onUse: (ClipboardItem) -> Void
    var onClose: () -> Void

    private var filtered: [ClipboardItem] {
        guard !query.isEmpty else { return store.items }
        return store.items.filter { $0.preview.localizedCaseInsensitiveContains(query) }
    }

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
            Image(systemName: "doc.on.clipboard").foregroundColor(.secondary)
            Text("Clipboard").font(.system(size: 13, weight: .semibold))
            Text("\(store.items.count)").font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.system(size: 11))
                TextField("Search", text: $query).textFieldStyle(.plain).frame(maxWidth: 220)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
            .padding(.leading, 8)

            Spacer()

            Button { ClipboardManager.shared.clearAll() } label: {
                Label("Clear", systemImage: "trash")
            }
            .buttonStyle(.borderless).help("Clear all")

            Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                .buttonStyle(.borderless).help("Close (Esc)")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if filtered.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray").font(.system(size: 26)).foregroundColor(.secondary)
                Text(query.isEmpty ? "No clipboard items yet" : "No matches")
                    .foregroundColor(.secondary).font(.system(size: 12))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 12) {
                    ForEach(filtered) { item in
                        ClipboardCard(item: item, onUse: onUse)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }
}

private struct ClipboardCard: View {
    let item: ClipboardItem
    var onUse: (ClipboardItem) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .frame(width: 200, height: 150)
                .frame(maxWidth: .infinity)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 6) {
                kindIcon.font(.system(size: 11)).foregroundColor(.secondary)
                if let app = item.sourceApp {
                    Text(app).font(.system(size: 11, weight: .medium)).lineLimit(1)
                }
                Spacer()
                if item.pinned { Image(systemName: "pin.fill").foregroundColor(.orange).font(.system(size: 10)) }
            }
            .padding(.top, 8)
            Text(item.date, style: .relative)
                .font(.system(size: 10)).foregroundColor(.secondary)
                .padding(.top, 2)
        }
        .padding(10)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(hovering ? 0.18 : 0.06), radius: hovering ? 8 : 3, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor.opacity(hovering ? 0.8 : 0), lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onUse(item) }
        .contextMenu {
            Button("Copy") { ClipboardManager.shared.copyToPasteboard(item) }
            Button("Paste to frontmost app") { onUse(item) }
            Button(item.pinned ? "Unpin" : "Pin") { ClipboardManager.shared.togglePin(item) }
            Divider()
            Button("Delete", role: .destructive) { ClipboardManager.shared.delete(item) }
        }
    }

    @ViewBuilder private var preview: some View {
        switch item.kind {
        case .image:
            if let url = ClipboardManager.shared.imageURL(for: item), let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").font(.system(size: 30)).foregroundColor(.secondary)
            }
        case .file:
            VStack(spacing: 6) {
                Image(systemName: "doc.fill").font(.system(size: 28)).foregroundColor(.secondary)
                Text(item.preview).font(.system(size: 11)).lineLimit(3)
                    .multilineTextAlignment(.center).padding(.horizontal, 6)
            }
        case .text:
            ScrollView {
                Text(item.preview)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
    }

    @ViewBuilder private var kindIcon: some View {
        switch item.kind {
        case .image: Image(systemName: "photo")
        case .file: Image(systemName: "doc")
        case .text: Image(systemName: "text.alignleft")
        }
    }
}

/// A borderless panel that can still become key (so the search field accepts
/// typing) and resolves Escape to close.
final class BottomBarPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Presents the clipboard history as a full-width bar docked to the bottom of
/// the active screen.
final class ClipboardHistoryController: NSObject, NSWindowDelegate {
    static let shared = ClipboardHistoryController()
    private var panel: BottomBarPanel?
    private let store = ClipboardStore()
    private let barHeight: CGFloat = 280

    func toggle(relativeTo statusButton: NSStatusBarButton?) {
        if let panel, panel.isVisible {
            hide()
            return
        }
        present()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func present() {
        let screen = activeScreen()
        let frame = NSRect(x: screen.frame.minX,
                           y: screen.visibleFrame.minY,
                           width: screen.frame.width,
                           height: barHeight)

        let root = ClipboardHistoryView(store: store, onUse: { [weak self] item in
            ClipboardManager.shared.copyToPasteboard(item, paste: true)
            self?.hide()
        }, onClose: { [weak self] in
            self?.hide()
        })

        let panel: BottomBarPanel
        if let existing = self.panel {
            panel = existing
            panel.setFrame(frame, display: true)
        } else {
            panel = BottomBarPanel(contentRect: frame,
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.onEscape = { [weak self] in self?.hide() }
            panel.contentView = NSHostingView(rootView: root)
            self.panel = panel
        }

        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        store.refresh()
    }

    /// The screen the pointer is on (so the bar appears where the user is working).
    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    // Auto-hide when the bar loses focus (click elsewhere).
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}
