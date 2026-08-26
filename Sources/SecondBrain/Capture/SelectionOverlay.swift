import AppKit

/// Describes a region the user selected on screen.
struct CaptureRegion {
    let displayID: CGDirectDisplayID
    /// Rect in display-local points, top-left origin (matches ScreenCaptureKit / CGImage).
    let rectInPoints: CGRect
    let scale: CGFloat
    let screen: NSScreen
    /// Overlay windows to keep out of the screenshot if they are still on-screen.
    let excludedWindowIDs: [CGWindowID]
}

/// Presents a translucent full-screen overlay on every connected display and
/// lets the user drag-select a rectangular region. Works across multiple
/// monitors: the drag is resolved on whichever display it occurs.
final class SelectionOverlay {
    private var windows: [SelectionWindow] = []
    private var completion: ((CaptureRegion?) -> Void)?
    private var eventMonitor: Any?
    private var didPushCursor = false

    static let shared = SelectionOverlay()
    private init() {}

    func begin(_ completion: @escaping (CaptureRegion?) -> Void) {
        guard windows.isEmpty else { return }
        self.completion = completion

        // Activate before the overlays appear, so the very first mouse-down is
        // delivered as a drag instead of being spent activating the app.
        NSApp.activate(ignoringOtherApps: true)

        let pointer = NSEvent.mouseLocation
        var windowUnderPointer: SelectionWindow?

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
            if NSMouseInRect(pointer, screen.frame, false) { windowUnderPointer = window }
        }

        // Key window so Escape and the crosshair work without a priming click.
        (windowUnderPointer ?? windows.first)?.makeKey()

        NSCursor.crosshair.push()
        didPushCursor = true

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
        if didPushCursor {
            NSCursor.pop()
            didPushCursor = false
        }
        let ids = windows.map { CGWindowID($0.windowNumber) }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()

        let enriched: CaptureRegion?
        if let region {
            enriched = CaptureRegion(
                displayID: region.displayID,
                rectInPoints: region.rectInPoints,
                scale: region.scale,
                screen: region.screen,
                excludedWindowIDs: ids
            )
        } else {
            enriched = nil
        }

        let handler = completion
        completion = nil
        handler?(enriched)
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
        backgroundColor = .clear
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

    /// Without this, AppKit spends the first click activating the window and the
    /// user has to click again before a drag registers.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
                                   rectInPoints: Self.pixelAlign(currentRect, scale: scale),
                                   scale: scale,
                                   screen: screenRef,
                                   excludedWindowIDs: [])
        onComplete?(region)
    }

    /// Snap the selection to device pixels so the capture crop doesn't resample.
    private static func pixelAlign(_ rect: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0 else { return rect }
        let x0 = (rect.minX * scale).rounded() / scale
        let y0 = (rect.minY * scale).rounded() / scale
        let x1 = (rect.maxX * scale).rounded() / scale
        let y1 = (rect.maxY * scale).rounded() / scale
        return CGRect(x: x0, y: y0, width: max(1 / scale, x1 - x0), height: max(1 / scale, y1 - y0))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Dim everything *except* the selection so the chosen pixels stay true.
        let dim = NSBezierPath(rect: bounds)
        if currentRect.width > 0, currentRect.height > 0 {
            dim.append(NSBezierPath(rect: currentRect))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()

        guard currentRect.width > 0, currentRect.height > 0 else { return }

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
