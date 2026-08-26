import AppKit

/// Visualises mouse clicks and keystrokes on screen while recording, so they end
/// up in the captured video. Clicks draw a fading ripple where they happen;
/// keystrokes appear as a caption near the bottom of the recorded display.
///
/// Mouse events need no extra permission. Keystrokes need Accessibility, so the
/// key caption is skipped (clicks still work) when that isn't granted.
@MainActor
final class InputOverlay {
    static let shared = InputOverlay()
    private init() {}

    private var clickWindow: NSWindow?
    private var keyWindow: NSWindow?
    private var keyLabel: NSTextField?
    private var monitors: [Any] = []
    private var keyCaptionHideWork: DispatchWorkItem?
    private var recentKeys: [String] = []
    private(set) var isActive = false

    /// Screen whose input is being visualised — matches the recorded display.
    private var screen: NSScreen?

    func start(on screen: NSScreen) {
        guard !isActive else { return }
        self.screen = screen
        isActive = true

        buildWindows(on: screen)
        installMonitors()
        Log.info("Input overlay started\(Permissions.hasAccessibility() ? "" : " (clicks only — no Accessibility)")")
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
        keyLabel = nil
        screen = nil
    }

    // MARK: - Windows

    private func buildWindows(on screen: NSScreen) {
        let clicks = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        clicks.isOpaque = false
        clicks.backgroundColor = .clear
        clicks.level = .screenSaver
        clicks.ignoresMouseEvents = true
        clicks.hasShadow = false
        clicks.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        clicks.contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        clicks.contentView?.wantsLayer = true
        clicks.orderFrontRegardless()
        clickWindow = clicks

        let captionHeight: CGFloat = 54
        let captionWidth: CGFloat = 520
        let captionFrame = NSRect(x: screen.frame.midX - captionWidth / 2,
                                  y: screen.visibleFrame.minY + 40,
                                  width: captionWidth, height: captionHeight)
        let caption = NSWindow(contentRect: captionFrame, styleMask: .borderless,
                               backing: .buffered, defer: false)
        caption.isOpaque = false
        caption.backgroundColor = .clear
        caption.level = .screenSaver
        caption.ignoresMouseEvents = true
        caption.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: captionFrame.size))
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

    // MARK: - Monitors

    private func installMonitors() {
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents, handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.showRipple(at: NSEvent.mouseLocation, rightClick: event.type == .rightMouseDown)
            }
        })
        if let mouseMonitor { monitors.append(mouseMonitor) }

        // Keyboard monitoring is only delivered to trusted (Accessibility) apps.
        guard Permissions.hasAccessibility() else { return }
        let keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.showKey(for: event) }
        })
        if let keyMonitor { monitors.append(keyMonitor) }
    }

    // MARK: - Click ripple

    private func showRipple(at globalPoint: CGPoint, rightClick: Bool) {
        guard let window = clickWindow, let container = window.contentView,
              let screen, NSMouseInRect(globalPoint, screen.frame, false) else { return }

        let local = CGPoint(x: globalPoint.x - screen.frame.minX,
                            y: globalPoint.y - screen.frame.minY)
        let diameter: CGFloat = 46
        let ripple = CALayer()
        ripple.frame = CGRect(x: local.x - diameter / 2, y: local.y - diameter / 2,
                              width: diameter, height: diameter)
        ripple.cornerRadius = diameter / 2
        let tint: NSColor = rightClick ? .systemOrange : .systemBlue
        ripple.backgroundColor = tint.withAlphaComponent(0.28).cgColor
        ripple.borderColor = tint.withAlphaComponent(0.9).cgColor
        ripple.borderWidth = 2
        container.layer?.addSublayer(ripple)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.35
        grow.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        ripple.add(group, forKey: "ripple")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ripple.removeFromSuperlayer() }
    }

    // MARK: - Key caption

    private func showKey(for event: NSEvent) {
        guard let description = Self.describe(event) else { return }
        recentKeys.append(description)
        if recentKeys.count > 6 { recentKeys.removeFirst(recentKeys.count - 6) }
        keyLabel?.stringValue = recentKeys.joined(separator: "  ")

        keyWindow?.animator().alphaValue = 1
        keyCaptionHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.recentKeys.removeAll()
            self?.keyWindow?.animator().alphaValue = 0
        }
        keyCaptionHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Human-readable label for a key press, e.g. "⌘⇧4" or "⏎".
    private static func describe(_ event: NSEvent) -> String? {
        var parts = ""
        let flags = event.modifierFlags
        if flags.contains(.control) { parts += "⌃" }
        if flags.contains(.option) { parts += "⌥" }
        if flags.contains(.shift) { parts += "⇧" }
        if flags.contains(.command) { parts += "⌘" }

        guard event.type == .keyDown else {
            // Modifier-only press: show the combination while it's held.
            return parts.isEmpty ? nil : parts
        }

        let named: [UInt16: String] = [
            36: "⏎", 48: "⇥", 49: "space", 51: "⌫", 53: "esc",
            123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        if let name = named[event.keyCode] { return parts + name }
        let characters = event.charactersIgnoringModifiers ?? ""
        guard !characters.isEmpty else { return parts.isEmpty ? nil : parts }
        return parts + characters.uppercased()
    }
}
