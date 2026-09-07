import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon's `RegisterEventHotKey`, which needs no Accessibility permission
/// and is dispatched by the window server rather than waking us on every event.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Carbon owns the callback lifetime and `deinit` is nonisolated in Swift 6, so the
    /// small registry uses an explicit lock rather than actor-isolated mutable globals.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var callbacks: [UInt32: @MainActor () -> Void] = [:]
        private var nextID: UInt32 = 1

        func insert(_ callback: @escaping @MainActor () -> Void) -> UInt32 {
            lock.lock()
            defer { lock.unlock() }
            let id = nextID
            nextID &+= 1
            callbacks[id] = callback
            return id
        }

        func callback(for id: UInt32) -> (@MainActor () -> Void)? {
            lock.lock()
            defer { lock.unlock() }
            return callbacks[id]
        }

        func remove(_ id: UInt32) {
            lock.lock()
            callbacks[id] = nil
            lock.unlock()
        }
    }

    private static let registry = Registry()

    private let id: UInt32

    /// - Returns: nil if the chord is already claimed by another app.
    init?(keyCode: UInt32, modifiers: UInt32, onFire: @escaping @MainActor () -> Void) {
        id = HotKey.registry.insert(onFire)

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            MainActor.assumeIsolated {
                HotKey.registry.callback(for: hkID.id)?()
            }
            return noErr
        }, 1, &eventType, nil, &handler)

        guard handlerStatus == noErr, handler != nil else {
            HotKey.registry.remove(id)
            return nil
        }

        let hkID = EventHotKeyID(signature: OSType(0x53504C54), id: id) // 'SPLT'
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, ref != nil else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            HotKey.registry.remove(id)
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        HotKey.registry.remove(id)
    }
}
