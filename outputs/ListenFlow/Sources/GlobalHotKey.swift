import AppKit
import Carbon.HIToolbox

/// A system-wide hot key, so recording can start or stop while another app has
/// focus. Carbon's `RegisterEventHotKey` is used rather than an `NSEvent` global
/// monitor because it works without requesting Accessibility permission.
final class GlobalHotKey {
    fileprivate static var active: GlobalHotKey?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x4C46_4C48 // 'LFLH'
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        // The handler must not capture; it routes through the static reference.
        let install = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, let key = GlobalHotKey.active, key.signature == id.signature else { return noErr }
            DispatchQueue.main.async { key.action() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        guard install == noErr else { return nil }

        let id = EventHotKeyID(signature: signature, id: 1)
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
        GlobalHotKey.active = self
    }

    /// ⌥⌘R — the same shortcut pattern as the in-window ⌘R.
    static func toggleRecording(action: @escaping () -> Void) -> GlobalHotKey? {
        GlobalHotKey(keyCode: UInt32(kVK_ANSI_R),
                     modifiers: UInt32(optionKey | cmdKey), action: action)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        if GlobalHotKey.active === self { GlobalHotKey.active = nil }
    }
}
