import Carbon.HIToolbox
import AppKit

/// Registers system-wide hotkeys via the Carbon Hot Key API (no Accessibility
/// permission required). Each hotkey maps to a closure.
final class HotKeyManager {
    static let shared = HotKeyManager()
    private init() {}

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var nextID: UInt32 = 1
    private var installed = false

    struct KeyCombo {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    func register(_ combo: KeyCombo, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = nextID; nextID += 1
        handlers[id] = action
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E4150 /* 'SNAP' */), id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            refs.append(ref)
        } else {
            Log.error("Failed to register hotkey id \(id): status \(status)")
        }
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.handlers[hkID.id]?() }
            return noErr
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, selfPtr, nil)
    }

    /// Registers the default Snapture hotkeys.
    func registerDefaults() {
        // ⌃⌥4 — capture area screenshot
        register(KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(controlKey | optionKey))) {
            ScreenshotManager.shared.captureRegionToClipboard()
        }
        // ⌃⌥5 — OCR capture
        register(KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(controlKey | optionKey))) {
            OCRManager.shared.captureRegionAndCopyText()
        }
        // ⌃⌥V — clipboard history
        register(KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey))) {
            ClipboardHistoryController.shared.toggle(relativeTo: nil)
        }
        // ⌃⌥6 — toggle screen recording
        register(KeyCombo(keyCode: UInt32(kVK_ANSI_6), modifiers: UInt32(controlKey | optionKey))) {
            RecordingCoordinator.shared.toggleScreenRecording()
        }
    }
}
