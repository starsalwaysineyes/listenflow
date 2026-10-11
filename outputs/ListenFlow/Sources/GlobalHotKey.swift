import AppKit
import Carbon.HIToolbox

/// A system-wide hot key, so recording can start or stop while another app has
/// focus. Carbon's `RegisterEventHotKey` is used rather than an `NSEvent` global
/// monitor because it works without requesting Accessibility permission.
final class GlobalHotKey {
    fileprivate static var registry: [UInt32: GlobalHotKey] = [:]

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    fileprivate let identifier: UInt32
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, identifier: UInt32, action: @escaping () -> Void) {
        self.action = action
        self.identifier = identifier
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        // The handler routes through the static registry, so it captures nothing.
        let install = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr,
                  let key = GlobalHotKey.registry[id.id] else { return noErr }
            DispatchQueue.main.async { key.action() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        guard install == noErr else { return nil }

        let id = EventHotKeyID(signature: 0x4C46_4C48 /* 'LFLH' */, id: identifier)
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
        GlobalHotKey.registry[identifier] = self
    }

    /// ⌥⌘R — mirrors the in-window ⌘R.
    static let toggleRecordingID: UInt32 = 1
    /// ⌥⌘S — grab a screen region into the pending question or organization.
    static let screenshotID: UInt32 = 2

    @discardableResult
    static func register(keyCode: UInt32, modifiers: UInt32, identifier: UInt32,
                         action: @escaping () -> Void) -> GlobalHotKey? {
        GlobalHotKey(keyCode: keyCode, modifiers: modifiers, identifier: identifier, action: action)
    }

    static func toggleRecording(action: @escaping () -> Void) -> GlobalHotKey? {
        register(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | cmdKey),
                 identifier: toggleRecordingID, action: action)
    }

    static func screenshot(action: @escaping () -> Void) -> GlobalHotKey? {
        register(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey | cmdKey),
                 identifier: screenshotID, action: action)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        GlobalHotKey.registry.removeValue(forKey: identifier)
    }
}
