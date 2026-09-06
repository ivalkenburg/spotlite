import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon's `RegisterEventHotKey`, which needs no Accessibility permission
/// and is dispatched by the window server rather than waking us on every event.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var callbacks: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1

    private let id: UInt32

    /// - Returns: nil if the chord is already claimed by another app.
    init?(keyCode: UInt32, modifiers: UInt32, onFire: @escaping () -> Void) {
        id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.callbacks[id] = onFire

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            HotKey.callbacks[hkID.id]?()
            return noErr
        }, 1, &eventType, nil, &handler)

        let hkID = EventHotKeyID(signature: OSType(0x53504C54), id: id) // 'SPLT'
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, ref != nil else {
            HotKey.callbacks[id] = nil
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        HotKey.callbacks[id] = nil
    }
}
