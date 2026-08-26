import AppKit

/// Draws input on screen while recording — click ripples, a keystroke caption,
/// and an optional coloured ring around the pointer — so everything the user did
/// is visible in the captured video. It also writes a machine-readable log of
/// those actions via `InputEventLog`.
///
/// Mouse events need no extra permission. Keystrokes need Accessibility, so the
/// caption and key log are skipped (clicks still work) when it isn't granted.
@MainActor
final class InputOverlay {
    static let shared = InputOverlay()
    private init() {}

    struct Options {
        /// Click ripples + keystroke caption, and the written event log.
        var showClicksAndKeys: Bool
        /// Persistent coloured ring following the pointer.
        var showMouseRing: Bool
        /// Where to write the JSONL action log, if anywhere.
        var logURL: URL?
    }

    private var clickWindow: NSWindow?
    private var keyWindow: NSWindow?
    private var keyLabel: NSTextField?
    private var ringWindow: NSWindow?
    private var monitors: [Any] = []
    private var keyCaptionHideWork: DispatchWorkItem?
    private var recentKeys: [String] = []
    private var eventLog: InputEventLog?
    private var options = Options(showClicksAndKeys: false, showMouseRing: false, logURL: nil)
    private(set) var isActive = false

    /// Screen whose input is being visualised — matches the recorded display.
    private var screen: NSScreen?

    private static let ringDiameter: CGFloat = 58

    func start(on screen: NSScreen, options: Options) {
        guard !isActive else { return }
        guard options.showClicksAndKeys || options.showMouseRing else { return }
        self.screen = screen
        self.options = options
        isActive = true

        if let logURL = options.logURL, options.showClicksAndKeys {
            eventLog = InputEventLog(url: logURL)
        }
        if options.showClicksAndKeys { buildClickAndKeyWindows(on: screen) }
        if options.showMouseRing { buildRingWindow() }
        installMonitors()

        var notes: [String] = []
        if options.showClicksAndKeys {
            notes.append(Permissions.hasAccessibility() ? "clicks + keys" : "clicks only (no Accessibility)")
        }
        if options.showMouseRing { notes.append("mouse ring") }
        Log.info("Input overlay started: \(notes.joined(separator: ", "))")
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        keyCaptionHideWork?.cancel()
        recentKeys.removeAll()
        clickWindow?.orderOut(nil); clickWindow = nil
        keyWindow?.orderOut(nil); keyWindow = nil
        ringWindow?.orderOut(nil); ringWindow = nil
        keyLabel = nil
        screen = nil
        if let eventLog {
            eventLog.flush()
            Log.info("Input log written -> \(eventLog.fileURL.lastPathComponent)")
        }
        eventLog = nil
    }

    // MARK: - Windows

    private func overlayWindow(frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return window
    }

    private func buildClickAndKeyWindows(on screen: NSScreen) {
        let clicks = overlayWindow(frame: screen.frame)
        let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        container.wantsLayer = true
        clicks.contentView = container
        clicks.orderFrontRegardless()
        clickWindow = clicks

        let captionSize = NSSize(width: 620, height: 54)
        let captionFrame = NSRect(x: screen.frame.midX - captionSize.width / 2,
                                  y: screen.visibleFrame.minY + 40,
                                  width: captionSize.width, height: captionSize.height)
        let caption = overlayWindow(frame: captionFrame)

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: captionSize))
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 20, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = blur.bounds.insetBy(dx: 12, dy: 12)
        label.autoresizingMask = [.width, .height]
        blur.addSubview(label)

        caption.contentView = blur
        caption.alphaValue = 0
        caption.orderFrontRegardless()
        keyWindow = caption
        keyLabel = label
    }

    /// Small window that trails the pointer with a rainbow ring drawn in it.
    private func buildRingWindow() {
        let size = Self.ringDiameter
        let window = overlayWindow(frame: NSRect(x: 0, y: 0, width: size, height: size))
        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true

        let gradient = CAGradientLayer()
        gradient.frame = view.bounds
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.colors = [
            NSColor.systemRed, .systemOrange, .systemYellow, .systemGreen,
            .systemTeal, .systemBlue, .systemPurple, .systemRed
        ].map { $0.withAlphaComponent(0.95).cgColor }

        // Mask the gradient down to a ring so the pointer stays visible.
        let ring = CAShapeLayer()
        let inset = 4.0
        ring.path = CGPath(ellipseIn: view.bounds.insetBy(dx: inset, dy: inset), transform: nil)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = NSColor.black.cgColor
        ring.lineWidth = 5
        gradient.mask = ring

        view.layer?.addSublayer(gradient)

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = Double.pi * 2
        spin.duration = 3.5
        spin.repeatCount = .infinity
        gradient.add(spin, forKey: "spin")

        window.contentView = view
        window.orderFrontRegardless()
        ringWindow = window
        moveRing(to: NSEvent.mouseLocation)
    }

    // MARK: - Monitors

    private func installMonitors() {
        if options.showMouseRing {
            let moveEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged,
                                                     .rightMouseDragged, .otherMouseDragged]
            let monitor = NSEvent.addGlobalMonitorForEvents(matching: moveEvents, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.moveRing(to: NSEvent.mouseLocation) }
            })
            if let monitor { monitors.append(monitor) }
        }

        guard options.showClicksAndKeys else { return }

        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleClick(event) }
        })
        if let mouseMonitor { monitors.append(mouseMonitor) }

        // Keyboard monitoring is only delivered to trusted (Accessibility) apps.
        guard Permissions.hasAccessibility() else { return }
        let keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) }
        })
        if let keyMonitor { monitors.append(keyMonitor) }
    }

    // MARK: - Mouse ring

    private func moveRing(to point: CGPoint) {
        guard let ringWindow else { return }
        let size = Self.ringDiameter
        ringWindow.setFrameOrigin(NSPoint(x: point.x - size / 2, y: point.y - size / 2))
    }

    // MARK: - Clicks

    private func handleClick(_ event: NSEvent) {
        let global = NSEvent.mouseLocation
        let button = event.buttonNumber
        showRipple(at: global, buttonNumber: button, clickCount: max(1, event.clickCount))

        guard let eventLog else { return }
        var logged = InputEventLog.Event(t: eventLog.elapsed(), type: "click")
        logged.button = InputNaming.mouseButton(button)
        logged.buttonNumber = button
        logged.clickCount = max(1, event.clickCount)
        if let local = displayLocalPoint(global) {
            logged.x = Double(local.x.rounded())
            logged.y = Double(local.y.rounded())
        }
        let modifiers = InputNaming.modifierNames(event.modifierFlags)
        logged.modifiers = modifiers.isEmpty ? nil : modifiers
        logged.app = NSWorkspace.shared.frontmostApplication?.localizedName
        eventLog.record(logged)
    }

    /// Pointer position inside the recorded display, top-left origin — the same
    /// space the video frames use.
    private func displayLocalPoint(_ global: CGPoint) -> CGPoint? {
        guard let screen, NSMouseInRect(global, screen.frame, false) else { return nil }
        return CGPoint(x: global.x - screen.frame.minX, y: screen.frame.maxY - global.y)
    }

    private func showRipple(at globalPoint: CGPoint, buttonNumber: Int, clickCount: Int) {
        guard let container = clickWindow?.contentView, let screen,
              NSMouseInRect(globalPoint, screen.frame, false) else { return }

        let local = CGPoint(x: globalPoint.x - screen.frame.minX,
                            y: globalPoint.y - screen.frame.minY)
        let tint = Self.tint(forButton: buttonNumber)
        let diameter: CGFloat = 46

        let ripple = CALayer()
        ripple.frame = CGRect(x: local.x - diameter / 2, y: local.y - diameter / 2,
                              width: diameter, height: diameter)
        ripple.cornerRadius = diameter / 2
        ripple.backgroundColor = tint.withAlphaComponent(0.28).cgColor
        ripple.borderColor = tint.withAlphaComponent(0.95).cgColor
        ripple.borderWidth = 2

        // Which button (and double-clicks) shown in the middle of the ripple, so
        // the video itself says what was pressed.
        let badge = CATextLayer()
        var mark = InputNaming.symbol(forMouseButton: buttonNumber)
        if clickCount > 1 { mark += "×\(clickCount)" }
        badge.string = mark
        badge.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        badge.fontSize = 15
        badge.foregroundColor = NSColor.white.cgColor
        badge.alignmentMode = .center
        badge.contentsScale = screen.backingScaleFactor
        badge.frame = CGRect(x: 0, y: diameter / 2 - 10, width: diameter, height: 20)
        ripple.addSublayer(badge)

        container.layer?.addSublayer(ripple)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.35
        grow.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        ripple.add(group, forKey: "ripple")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { ripple.removeFromSuperlayer() }
    }

    private static func tint(forButton number: Int) -> NSColor {
        switch number {
        case 0: return .systemBlue
        case 1: return .systemOrange
        case 2: return .systemGreen
        default: return .systemPurple
        }
    }

    // MARK: - Keystrokes

    private func handleKey(_ event: NSEvent) {
        if let symbol = InputNaming.keySymbol(event) {
            recentKeys.append(symbol)
            if recentKeys.count > 8 { recentKeys.removeFirst(recentKeys.count - 8) }
            keyLabel?.stringValue = recentKeys.joined(separator: "  ")
            keyWindow?.animator().alphaValue = 1
            keyCaptionHideWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.recentKeys.removeAll()
                self?.keyWindow?.animator().alphaValue = 0
            }
            keyCaptionHideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
        }

        guard let eventLog else { return }
        var logged = InputEventLog.Event(t: eventLog.elapsed(), type: "key")
        logged.key = InputNaming.keyName(event)
        logged.combo = InputNaming.keySymbol(event)
        logged.keyCode = Int(event.keyCode)
        let modifiers = InputNaming.modifierNames(event.modifierFlags)
        logged.modifiers = modifiers.isEmpty ? nil : modifiers
        logged.app = NSWorkspace.shared.frontmostApplication?.localizedName
        eventLog.record(logged)
    }
}
