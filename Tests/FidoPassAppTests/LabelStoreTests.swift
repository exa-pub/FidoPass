import XCTest
import FidoPassCore
@testable import FidoPassApp
import TestSupport

/// Labels are not secret, but forgetting one makes its password unreproducible — so the
/// history has to survive relaunches, merge across devices, and never quietly come back
/// after the user clears it.
final class LabelStoreTests: XCTestCase {

    @MainActor
    func testLoadMergesCloudValues() {
        let cloud = InMemoryUbiquitousStore()
        cloud.set(["cloud1", "local"], forKey: "recentLabels")
        let defaults = Self.defaults(seeded: ["local"])

        let store = LabelStore(userDefaults: defaults, ubiStore: cloud, notificationCenter: NotificationCenter())
        XCTAssertEqual(store.recent, ["cloud1", "local"])
    }

    @MainActor
    func testMergeAppendsNewCloudEntries() {
        let cloud = InMemoryUbiquitousStore()
        let defaults = Self.defaults(seeded: ["local"])
        let store = LabelStore(userDefaults: defaults, ubiStore: cloud, notificationCenter: NotificationCenter())

        cloud.set(["cloudA", "cloudB"], forKey: "recentLabels")
        store.mergeUbiquitous()

        XCTAssertEqual(store.recent, ["local", "cloudA", "cloudB"])
        XCTAssertEqual(defaults.array(forKey: "recentLabels") as? [String], ["local", "cloudA", "cloudB"])
    }

    @MainActor
    func testUsingALabelDeduplicatesAndCaps() {
        let store = LabelStore(userDefaults: Self.defaults(),
                               ubiStore: InMemoryUbiquitousStore(),
                               notificationCenter: NotificationCenter())
        for index in 0..<12 { store.use("label-\(index)") }
        store.use("label-5")

        XCTAssertEqual(store.recent.first, "label-5")
        XCTAssertEqual(store.recent.count, LabelStore.limit)
        XCTAssertEqual(store.current, "label-5")
    }

    /// Whitespace around a label would derive a different password from the one the user
    /// thinks they typed.
    @MainActor
    func testLabelsAreTrimmedAndBlanksIgnored() {
        let store = LabelStore(userDefaults: Self.defaults(),
                               ubiStore: InMemoryUbiquitousStore(),
                               notificationCenter: NotificationCenter())
        store.use("  work  ")
        XCTAssertEqual(store.recent, ["work"])

        store.use("   ")
        XCTAssertEqual(store.recent, ["work"], "a blank label is not a label")
    }

    /// Clearing only the in-memory list used to leave the values in UserDefaults and iCloud,
    /// so they reappeared on the next launch.
    @MainActor
    func testClearingWipesStorageToo() {
        let defaults = Self.defaults()
        let cloud = InMemoryUbiquitousStore()
        let store = LabelStore(userDefaults: defaults, ubiStore: cloud, notificationCenter: NotificationCenter())
        store.use("work")
        store.clearRecent()

        XCTAssertTrue(store.recent.isEmpty)
        XCTAssertEqual(defaults.array(forKey: "recentLabels") as? [String], [])
        XCTAssertEqual(cloud.array(forKey: "recentLabels") as? [String], [])
    }

    private static func defaults(seeded: [String]? = nil) -> UserDefaults {
        let suite = "LabelStore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if let seeded { defaults.set(seeded, forKey: "recentLabels") }
        return defaults
    }
}

/// What the app is allowed to remember between launches.
final class PreferencesTests: XCTestCase {

    @MainActor
    func testLastUsedSurvivesAReconnectByVendorAndProduct() {
        let preferences = Preferences(defaults: Self.defaults())
        let device = MockKeyBackend.device(path: "/dev/one")
        preferences.remember(accountId: "vault", label: "work", device: device)

        // Same key, new session handle: the memory has to still apply.
        let reconnected = MockKeyBackend.device(path: "/dev/whatever-else")
        XCTAssertEqual(preferences.lastUsed?.deviceSignature, Preferences.signature(for: reconnected))
    }

    /// The account id is the only piece of account data that reaches the disk, and it is
    /// opt-out — turning the switch off must erase what was already written.
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

    private static func defaults() -> UserDefaults {
        let suite = "Preferences-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
