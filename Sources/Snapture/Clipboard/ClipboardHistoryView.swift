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

struct ClipboardHistoryView: View {
    @ObservedObject var store: ClipboardStore
    @State private var query: String = ""
    var onUse: (ClipboardItem) -> Void

    private var filtered: [ClipboardItem] {
        guard !query.isEmpty else { return store.items }
        return store.items.filter { $0.preview.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search clipboard history", text: $query)
                    .textFieldStyle(.plain)
                Spacer()
                Button(role: .destructive) {
                    ClipboardManager.shared.clearAll()
                } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Clear all")
            }
            .padding(8)
            Divider()

            if filtered.isEmpty {
                Spacer()
                Text("No clipboard items yet")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filtered) { item in
                            ClipboardRow(item: item, onUse: onUse)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(width: 360, height: 460)
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    var onUse: (ClipboardItem) -> Void

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview)
                    .lineLimit(2)
                    .font(.system(size: 12))
                HStack(spacing: 6) {
                    if let app = item.sourceApp {
                        Text(app).font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    Text(item.date, style: .relative)
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            Spacer()
            if item.pinned { Image(systemName: "pin.fill").foregroundColor(.orange).font(.system(size: 10)) }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture { onUse(item) }
        .contextMenu {
            Button("Copy") { ClipboardManager.shared.copyToPasteboard(item) }
            Button("Paste to frontmost app") { onUse(item) }
            Button(item.pinned ? "Unpin" : "Pin") { ClipboardManager.shared.togglePin(item) }
            Divider()
            Button("Delete", role: .destructive) { ClipboardManager.shared.delete(item) }
        }
    }

    @ViewBuilder private var icon: some View {
        switch item.kind {
        case .image:
            if let url = ClipboardManager.shared.imageURL(for: item), let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage).resizable().scaledToFill()
                    .frame(width: 36, height: 36).clipped().cornerRadius(6)
            } else {
                Image(systemName: "photo").frame(width: 36, height: 36)
            }
        case .file:
            Image(systemName: "doc").frame(width: 36, height: 36)
        case .text:
            Image(systemName: "text.alignleft").frame(width: 36, height: 36)
        }
    }
}

/// Hosts the SwiftUI history view inside a borderless panel anchored to the
/// menu bar item.
final class ClipboardHistoryController {
    static let shared = ClipboardHistoryController()
    private var panel: NSPanel?
    private let store = ClipboardStore()

    func toggle(relativeTo statusButton: NSStatusBarButton?) {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        present(relativeTo: statusButton)
    }

    private func present(relativeTo statusButton: NSStatusBarButton?) {
        let root = ClipboardHistoryView(store: store) { [weak self] item in
            ClipboardManager.shared.copyToPasteboard(item, paste: true)
            self?.panel?.orderOut(nil)
        }
        let hosting = NSHostingView(rootView: root)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 460),
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false

        if let button = statusButton, let screen = button.window?.screen {
            let buttonRect = button.window?.convertToScreen(button.frame) ?? .zero
            var origin = NSPoint(x: buttonRect.midX - 180, y: buttonRect.minY - 466)
            origin.x = max(screen.frame.minX + 8, min(origin.x, screen.frame.maxX - 368))
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
        store.refresh()
    }
}
