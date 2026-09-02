import Carbon.HIToolbox
import Foundation

/// What registers a system-wide shortcut. `GlobalHotkeyService` is the real one; a test
/// substitutes a recorder.
@MainActor
protocol HotkeyRegistrar: AnyObject {
    /// - Returns: false when the combination is already taken by something else, so the UI
    ///   can say so instead of silently doing nothing.
    func register(_ combo: HotkeyCombo, onPress: @escaping @MainActor () -> Void) -> Bool
    func unregister()
}

/// System-wide shortcut that opens the HUD.
///
/// Carbon's `RegisterEventHotKey` is used rather than an `NSEvent` global monitor because
/// the monitor needs Accessibility permission. Asking for that would be a poor trade for an
/// app whose pitch is that it holds nothing and watches nothing.
@MainActor
final class GlobalHotkeyService: HotkeyRegistrar {

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onPress: (@MainActor () -> Void)?
    private let signature: OSType = 0x46_44_50_53 // 'FDPS'

    init() {}

    @discardableResult
    func register(_ combo: HotkeyCombo, onPress: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        self.onPress = onPress

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        // A C function pointer cannot capture, so the instance travels as the handler's
        // user data — the same device `DeviceMonitorService` uses for its IOKit callbacks.
        // Carbon dispatches on the main run loop, hence the assumption rather than a hop.
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let service = Unmanaged<GlobalHotkeyService>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { service.fire() }
            return noErr
        }
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, context, &handlerRef)

        let id = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        onPress = nil
    }

    private func fire() {
        onPress?()
    }
}
