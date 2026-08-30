#if canImport(Carbon)
import Carbon.HIToolbox
import Foundation

/// System-wide shortcut that opens the HUD.
///
/// Carbon's `RegisterEventHotKey` is used rather than an `NSEvent` global monitor because
/// the monitor needs Accessibility permission. Asking for that would be a poor trade for an
/// app whose pitch is that it holds nothing and watches nothing.
final class GlobalHotkeyService {

    static let shared = GlobalHotkeyService()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onPress: (() -> Void)?
    private let signature: OSType = 0x46_44_50_53 // 'FDPS'

    private init() {}

    /// - Returns: false when the combination is already taken by something else, so the UI
    ///   can say so instead of silently doing nothing.
    @discardableResult
    func register(_ combo: HotkeyCombo, onPress: @escaping () -> Void) -> Bool {
        unregister()
        self.onPress = onPress

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, _ in
            GlobalHotkeyService.shared.fire()
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &handlerRef)

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

    fileprivate func fire() {
        onPress?()
    }
}
#endif
