import Foundation
import FidoPassCore
import ServiceManagement

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
        static let showInDock = "hud.showInDock"
        static let lockTimeout = "hud.lockTimeout"
        static let hotkey = "hud.hotkey"
        static let hotkeyEnabled = "hud.hotkeyEnabled"
        static let hasOnboarded = "hud.hasOnboarded"
    }

    @Published var rememberLastUsed: Bool { didSet { defaults.set(rememberLastUsed, forKey: Key.rememberLastUsed)
        if !rememberLastUsed { forgetLastUsed() } } }
    /// How long an unlocked key stays unlocked without being used.
    ///
    /// The PIN lives in memory for exactly this long, and every use of the key pushes the
    /// deadline out again. Locking the Mac or unplugging the key locks it at once, whatever
    /// this says.
    @Published var lockTimeout: TimeInterval { didSet {
        defaults.set(lockTimeout, forKey: Key.lockTimeout)
        onLockTimeoutChanged?(lockTimeout) } }
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

    /// The lock timeouts offered in Preferences, in seconds.
    ///
    /// No "never": the PIN is held in memory, and a key that never locks itself is one a
    /// borrowed Mac can generate passwords from all day.
    nonisolated static let lockTimeoutChoices: [TimeInterval] = [60, 300, 900, 1800, 3600]

    var onHotkeyChanged: (() -> Void)?
    var onLockTimeoutChanged: ((TimeInterval) -> Void)?
    var onShowInDockChanged: ((Bool) -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.rememberLastUsed = defaults.object(forKey: Key.rememberLastUsed) as? Bool ?? true
        self.showInDock = defaults.object(forKey: Key.showInDock) as? Bool ?? false
        let storedTimeout = defaults.object(forKey: Key.lockTimeout) as? TimeInterval
        self.lockTimeout = Self.lockTimeoutChoices.contains(storedTimeout ?? 0) ? storedTimeout! : 300
        self.hotkeyEnabled = defaults.object(forKey: Key.hotkeyEnabled) as? Bool ?? true
        self.hasOnboarded = defaults.bool(forKey: Key.hasOnboarded)
        self.hotkey = Self.read(HotkeyCombo.self, from: defaults, key: Key.hotkey) ?? .default
        self.lastUsed = Self.read(LastUsed.self, from: defaults, key: Key.lastUsed)
    }

    // MARK: - Last used


    func remember(accountId: String, label: String, device: FidoDevice) {
        guard rememberLastUsed else { return }
        let value = LastUsed(deviceSignature: device.modelSignature, accountId: accountId, label: label)
        lastUsed = value
        store(value, forKey: Key.lastUsed)
    }

    func forgetLastUsed() {
        lastUsed = nil
        defaults.removeObject(forKey: Key.lastUsed)
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
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
