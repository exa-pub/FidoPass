import XCTest
import FidoPassCore
@testable import FidoPassApp
import TestSupport

final class RecentLabelsPersistenceTests: XCTestCase {
    @MainActor
    func testLoadRecentLabelsMergesCloudValues() async throws {
        let store = InMemoryUbiquitousStore()
        store.set(["cloud1", "local"], forKey: "recentLabels")

        let suite = "RecentLabels-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(["local"], forKey: "recentLabels")

        let vm = makeViewModel(ubiStore: store, userDefaults: defaults, defaultsSuite: suite)
        let labels = vm.recentLabels
        XCTAssertEqual(labels, ["cloud1", "local"])
    }

    @MainActor
    func testMergeUbiquitousAppendsNewEntries() async throws {
        let store = InMemoryUbiquitousStore()
        let suite = "RecentLabelsMerge-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(["local"], forKey: "recentLabels")

        let vm = makeViewModel(ubiStore: store, userDefaults: defaults, defaultsSuite: suite)
        store.set(["cloudA", "cloudB"], forKey: "recentLabels")

        vm.mergeUbiquitous()
        let labels = vm.recentLabels
        XCTAssertEqual(labels, ["local", "cloudA", "cloudB"])
        XCTAssertEqual(defaults.array(forKey: "recentLabels") as? [String], ["local", "cloudA", "cloudB"])
    }

    @MainActor
    func testAddRecentLabelDeduplicatesAndCaps() async throws {
        let vm = makeViewModel()
        for index in 0..<12 {
            vm.addRecentLabel("label-\(index)")
        }
        vm.addRecentLabel("label-5")
        let labels = vm.recentLabels
        XCTAssertEqual(labels.first, "label-5")
        XCTAssertEqual(labels.count, 10)
    }

    @MainActor
    private func makeViewModel(ubiStore: NSUbiquitousKeyValueStore = InMemoryUbiquitousStore(),
                                userDefaults: UserDefaults? = nil,
                                defaultsSuite: String? = nil) -> AccountsViewModel {
        let defaults: UserDefaults
        if let provided = userDefaults {
            defaults = provided
        } else {
            let suite = defaultsSuite ?? "RecentLabelsDefault-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
        }
        let core = FidoPassCore(deviceRepository: MockDeviceRepository(),
                                enrollmentService: MockEnrollmentService(),
                                portableEnrollmentService: MockPortableEnrollmentService(),
                                secretDerivationService: MockSecretDerivationService(),
                                passwordGenerator: MockPasswordGenerator())
        return AccountsViewModel(core: core,
                                 pinVault: SecurePinVault(defaultTTL: 60),
                                 pinTTL: 60,
                                 deviceWorkQueue: DispatchQueue(label: "recent.labels.queue"),
                                 ubiStore: ubiStore,
                                 userDefaults: defaults,
                                 notificationCenter: NotificationCenter(),
                                 enableDeviceMonitors: false)
    }
}
