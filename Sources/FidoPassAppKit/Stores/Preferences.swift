import Foundation
import FidoPassCore

/// Persists preferences and public account metadata; never secrets.
@MainActor
final class Preferences: ObservableObject {

    /// Persisted selection. credentialId identifies the account; model metadata is display-only.
    struct LastUsed: Codable, Equatable {
        var deviceSignature: String
        var accountId: String
        var label: String
        var credentialId: String? = nil
    }

    /// Persisted format. `hud.` is history — the keys stay whatever the code calls the panel.
    private enum Key {
        static let rememberLastUsed = "hud.rememberLastUsed"
        static let lastUsed = "hud.lastUsed"
        static let showInDock = "hud.showInDock"
        static let lockTimeout = "hud.lockTimeout"
        static let hotkey = "hud.hotkey"
        static let hotkeyEnabled = "hud.hotkeyEnabled"
        static let hasOnboarded = "hud.hasOnboarded"
    }

    @Published var rememberLastUsed: Bool {
        didSet {
            defaults.set(rememberLastUsed, forKey: Key.rememberLastUsed)
            if !rememberLastUsed { forgetLastUsed() }
        }
    }
    /// How long an unlocked key stays unlocked without being used.
    ///
    /// The PIN lives in memory for exactly this long, and every use of the key pushes the
    /// deadline out again. Locking the Mac or unplugging the key locks it at once, whatever
    /// this says.
    @Published var lockTimeout: TimeInterval {
        didSet { defaults.set(lockTimeout, forKey: Key.lockTimeout) }
    }
    @Published var showInDock: Bool {
        didSet { defaults.set(showInDock, forKey: Key.showInDock) }
    }
    @Published var hotkeyEnabled: Bool {
        didSet { defaults.set(hotkeyEnabled, forKey: Key.hotkeyEnabled) }
    }
    @Published var hotkey: HotkeyCombo {
        didSet { store(hotkey, forKey: Key.hotkey) }
    }
    @Published private(set) var lastUsed: LastUsed?
    @Published var hasOnboarded: Bool {
        didSet { defaults.set(hasOnboarded, forKey: Key.hasOnboarded) }
    }

    /// The lock timeouts offered in Preferences, in seconds.
    ///
    /// No "never": the PIN is held in memory, and a key that never locks itself is one a
    /// borrowed Mac can generate passwords from all day.
    nonisolated static let lockTimeoutChoices: [TimeInterval] = [60, 300, 900, 1800, 3600]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.rememberLastUsed = defaults.object(forKey: Key.rememberLastUsed) as? Bool ?? true
        self.showInDock = defaults.object(forKey: Key.showInDock) as? Bool ?? false
        let storedTimeout = defaults.object(forKey: Key.lockTimeout) as? TimeInterval
        self.lockTimeout = storedTimeout.flatMap { Self.lockTimeoutChoices.contains($0) ? $0 : nil } ?? 300
        self.hotkeyEnabled = defaults.object(forKey: Key.hotkeyEnabled) as? Bool ?? true
        self.hasOnboarded = defaults.bool(forKey: Key.hasOnboarded)
        self.hotkey = Self.read(HotkeyCombo.self, from: defaults, key: Key.hotkey) ?? .default
        self.lastUsed = Self.read(LastUsed.self, from: defaults, key: Key.lastUsed)
    }

    // MARK: - Last used

    func remember(accountId: String, label: String, device: FidoDevice, credentialId: String? = nil) {
        guard rememberLastUsed else { return }
        let value = LastUsed(deviceSignature: device.modelSignature, accountId: accountId, label: label, credentialId: credentialId)
        lastUsed = value
        store(value, forKey: Key.lastUsed)
    }

    func forgetLastUsed() {
        lastUsed = nil
        defaults.removeObject(forKey: Key.lastUsed)
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
