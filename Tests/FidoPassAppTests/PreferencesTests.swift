import XCTest
@testable import FidoPassAppKit

/// What the app is allowed to remember between launches.
final class PreferencesTests: AppTestCase {

    @MainActor
    func testLastUsedPreservesDisplayMetadataAcrossReconnects() {
        let preferences = Preferences(defaults: Self.defaults())
        let device = MockKeyBackend.device(path: "/dev/one")
        preferences.remember(accountId: "vault", label: "work", device: device)

        // Model metadata survives a path change; it does not establish key identity.
        let reconnected = MockKeyBackend.device(path: "/dev/whatever-else")
        XCTAssertEqual(preferences.lastUsed?.deviceSignature, reconnected.modelSignature)
    }

    /// Opting out removes saved selection metadata and prevents subsequent writes.
    @MainActor
    func testTurningOffTheMemoryForgetsWhatWasStored() {
        let defaults = Self.defaults()
        let preferences = Preferences(defaults: defaults)
        preferences.remember(accountId: "vault", label: "work", device: MockKeyBackend.device())
        XCTAssertNotNil(preferences.lastUsed)

        preferences.rememberLastUsed = false
        XCTAssertNil(preferences.lastUsed)
        XCTAssertNil(defaults.data(forKey: "hud.lastUsed"))

        preferences.remember(accountId: "vault", label: "work", device: MockKeyBackend.device())
        XCTAssertNil(preferences.lastUsed, "with the switch off, nothing new may be recorded either")
    }

    /// The timeout is what stands between "unlocked" and "anyone at this Mac can generate
    /// this vault's master password", so it has to survive a relaunch exactly as chosen.
    @MainActor
    func testLockTimeoutIsRememberedAndFallsBackToAKnownValue() {
        let defaults = Self.defaults()
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.lockTimeout, 300)

        preferences.lockTimeout = 900
        XCTAssertEqual(Preferences(defaults: defaults).lockTimeout, 900)

        // A value from a future version, or a hand-edited plist, must not become a timeout
        // nobody can see or change in the picker.
        defaults.set(7.0, forKey: "hud.lockTimeout")
        XCTAssertEqual(Preferences(defaults: defaults).lockTimeout, 300)
    }

    @MainActor
    private static func defaults() -> UserDefaults {
        let suite = "Preferences-\(UUID().uuidString)"
        let defaults = AppTestFactory.makeDefaults(suite: suite)
        return defaults
    }
}
