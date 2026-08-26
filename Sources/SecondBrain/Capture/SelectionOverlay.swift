import AppKit

/// Describes a region the user selected on screen.
struct CaptureRegion {
    let displayID: CGDirectDisplayID
    /// Rect in display-local points, top-left origin (matches ScreenCaptureKit sourceRect).
    let rectInPoints: CGRect
    let scale: CGFloat
    let screen: NSScreen
}

/// Presents a translucent full-screen overlay on every connected display and
/// lets the user drag-select a rectangular region. Works across multiple
/// monitors: the drag is resolved on whichever display it occurs.
final class SelectionOverlay {
    private var windows: [SelectionWindow] = []
    private var completion: ((CaptureRegion?) -> Void)?
    private var eventMonitor: Any?

    static let shared = SelectionOverlay()
    private init() {}

    func begin(_ completion: @escaping (CaptureRegion?) -> Void) {
        guard windows.isEmpty else { return }
        self.completion = completion

        for screen in NSScreen.screens {
            let window = SelectionWindow(screen: screen)
            window.onComplete = { [weak self] region in
                self?.finish(with: region)
            }
            window.onCancel = { [weak self] in
                self?.finish(with: nil)
            }
            window.orderFrontRegardless()
            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)

        // Global Escape to cancel.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.finish(with: nil)
                return nil
            }
            return event
        }
    }

    private func finish(with region: CaptureRegion?) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        let handler = completion
        completion = nil
        handler?(region)
    }
}

/// Borderless transparent window covering a single screen.
final class SelectionWindow: NSWindow {
    var onComplete: ((CaptureRegion) -> Void)?
    var onCancel: (() -> Void)?
    private let overlayScreen: NSScreen

    init(screen: NSScreen) {
        self.overlayScreen = screen
        super.init(contentRect: screen.frame,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.18)
        level = .screenSaver
        ignoresMouseEvents = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), screen: screen)
        view.onComplete = { [weak self] region in self?.onComplete?(region) }
        view.onCancel = { [weak self] in self?.onCancel?() }
        contentView = view
    }

    override var canBecomeKey: Bool { true }
}

/// Flipped view so local coordinates use a top-left origin, matching the
/// display coordinate space ScreenCaptureKit expects.
final class SelectionView: NSView {
    var onComplete: ((CaptureRegion) -> Void)?
    var onCancel: (() -> Void)?

    private let screenRef: NSScreen
    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero

    init(frame: NSRect, screen: NSScreen) {
        self.screenRef = screen
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(x: min(start.x, p.x),
                             y: min(start.y, p.y),
                             width: abs(p.x - start.x),
                             height: abs(p.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { startPoint = nil }
        guard currentRect.width > 3, currentRect.height > 3 else {
            onCancel?()
            return
        }
        let displayID = screenRef.displayID
        let scale = screenRef.backingScaleFactor
        let region = CaptureRegion(displayID: displayID,
                                   rectInPoints: currentRect,
                                   scale: scale,
                                   screen: screenRef)
        onComplete?(region)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard currentRect.width > 0, currentRect.height > 0 else { return }

        // Clear the selected region so the user sees through to the content.
        NSColor.clear.set()
        currentRect.fill(using: .copy)

        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: currentRect)
        path.lineWidth = 2
        path.stroke()

        // Dimensions label.
        let dims = "\(Int(currentRect.width)) × \(Int(currentRect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.6)
        ]
        let str = NSAttributedString(string: " \(dims) ", attributes: attrs)
        str.draw(at: NSPoint(x: currentRect.minX, y: max(0, currentRect.minY - 18)))
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
}
