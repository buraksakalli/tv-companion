import Carbon.HIToolbox
import Foundation

/// System-wide hotkey via Carbon's RegisterEventHotKey. Unlike event taps, this needs
/// no Accessibility / Input Monitoring permission.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void
    private static var nextID: UInt32 = 1

    init?(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        self.action = action
        let id = EventHotKeyID(signature: OSType(0x5456_4350) /* 'TVCP' */, id: Self.nextID)
        Self.nextID += 1

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon in
            guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let me = Unmanaged<HotKey>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated {
                guard pressed.id == me.hotKeyID else { return OSStatus(eventNotHandledErr) }
                me.action()
                return noErr
            }
        }, 1, &spec, refcon, &handlerRef)
        guard installed == noErr,
              RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref) == noErr
        else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
        hotKeyID = id.id
    }

    private var hotKeyID: UInt32 = 0

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        ref = nil
        handlerRef = nil
    }
}
