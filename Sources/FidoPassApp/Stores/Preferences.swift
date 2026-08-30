import Foundation
import FidoPassCore
#if canImport(ServiceManagement)
import ServiceManagement
#endif

/// A key combination registered system-wide.
struct HotkeyCombo: Codable, Equatable, Sendable {
    /// Virtual key code (`kVK_ANSI_P` and friends).
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, …).
    var modifiers: UInt32
    /// What to print in the UI. Stored rather than derived so the display never disagrees
    /// with what was actually registered.
    var display: String

    /// ⌘⌥P — "password", and unlikely to be taken by anything else.
    static let `default` = HotkeyCombo(keyCode: 35, modifiers: 0x0100 | 0x0800, display: "⌘⌥P")
}

/// What the app remembers between launches.
///
/// Deliberately small. No password, PIN or backup key ever reaches this file, and the one
/// piece of account data it does hold — the last used account id — is opt-out.
@MainActor
final class Preferences: ObservableObject {

    /// The account the HUD should preselect, addressed in a way that survives replugging.
    ///
    /// Device paths change on every reconnect, so they cannot be stored. A vendor/product
    /// signature is stable, imprecise only if the user owns two identical keys — in which
    /// case the worst outcome is that the wrong one is preselected and one click fixes it.
    struct LastUsed: Codable, Equatable {
        var deviceSignature: String
        var accountId: String
        var label: String
    }

    private enum Key {
        static let rememberLastUsed = "hud.rememberLastUsed"
        static let lastUsed = "hud.lastUsed"
        static let autoCloseAfterCopy = "hud.autoCloseAfterCopy"
        static let showInDock = "hud.showInDock"
        static let hotkey = "hud.hotkey"
        static let hotkeyEnabled = "hud.hotkeyEnabled"
        static let hasOnboarded = "hud.hasOnboarded"
    }

    @Published var rememberLastUsed: Bool { didSet { defaults.set(rememberLastUsed, forKey: Key.rememberLastUsed)
        if !rememberLastUsed { forgetLastUsed() } } }
    @Published var autoCloseAfterCopy: Bool { didSet { defaults.set(autoCloseAfterCopy, forKey: Key.autoCloseAfterCopy) } }
    @Published var showInDock: Bool { didSet { defaults.set(showInDock, forKey: Key.showInDock); onShowInDockChanged?(showInDock) } }
    @Published var hotkeyEnabled: Bool { didSet { defaults.set(hotkeyEnabled, forKey: Key.hotkeyEnabled); onHotkeyChanged?() } }
    @Published var hotkey: HotkeyCombo { didSet { store(hotkey, forKey: Key.hotkey); onHotkeyChanged?() } }
    @Published private(set) var lastUsed: LastUsed?
    /// Set when the system refused to register the shortcut — almost always because another
    /// application already owns it.
    @Published var hotkeyRegistrationFailed = false
    /// True while the settings window is capturing a new combination.
    ///
    /// The global shortcut is released meanwhile: Carbon dispatches a registered hot key
    /// before any window sees the key, so pressing the *current* combination would fire the
    /// HUD instead of being recorded as the new one.
    @Published var isRecordingHotkey = false { didSet { onHotkeyChanged?() } }
    @Published var hasOnboarded: Bool { didSet { defaults.set(hasOnboarded, forKey: Key.hasOnboarded) } }

    var onHotkeyChanged: (() -> Void)?
    var onShowInDockChanged: ((Bool) -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.rememberLastUsed = defaults.object(forKey: Key.rememberLastUsed) as? Bool ?? true
        self.autoCloseAfterCopy = defaults.object(forKey: Key.autoCloseAfterCopy) as? Bool ?? true
        self.showInDock = defaults.object(forKey: Key.showInDock) as? Bool ?? false
        self.hotkeyEnabled = defaults.object(forKey: Key.hotkeyEnabled) as? Bool ?? true
        self.hasOnboarded = defaults.bool(forKey: Key.hasOnboarded)
        self.hotkey = Self.read(HotkeyCombo.self, from: defaults, key: Key.hotkey) ?? .default
        self.lastUsed = Self.read(LastUsed.self, from: defaults, key: Key.lastUsed)
    }

    // MARK: - Last used

    nonisolated static func signature(for device: FidoDevice) -> String {
        String(format: "%04X:%04X", device.vendorId, device.productId)
    }

    func remember(accountId: String, label: String, device: FidoDevice) {
        guard rememberLastUsed else { return }
        let value = LastUsed(deviceSignature: Self.signature(for: device), accountId: accountId, label: label)
        lastUsed = value
        store(value, forKey: Key.lastUsed)
    }

    func forgetLastUsed() {
        lastUsed = nil
        defaults.removeObject(forKey: Key.lastUsed)
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get {
#if canImport(ServiceManagement)
            if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
#endif
            return false
        }
        set {
#if canImport(ServiceManagement)
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    // Registration fails for an app that is not in /Applications, which is
                    // normal during development. Surfacing it as a crash would be worse than
                    // leaving the switch where the user put it.
                    NSLog("FidoPass: launch at login change failed")
                }
                objectWillChange.send()
            }
#endif
        }
    }

    // MARK: - Codable storage

    private func store<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func read<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
