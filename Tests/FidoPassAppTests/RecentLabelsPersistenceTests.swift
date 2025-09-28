import XCTest
import FidoPassCore
@testable import FidoPassApp
import TestSupport

@MainActor
final class RecentLabelsPersistenceTests: XCTestCase {
    func testLoadRecentLabelsMergesCloudValues() {
        let store = InMemoryUbiquitousStore()
        store.set(["cloud1", "local"], forKey: "recentLabels")

        let suite = "RecentLabels-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(["local"], forKey: "recentLabels")

        let vm = makeViewModel(ubiStore: store, userDefaults: defaults, defaultsSuite: suite)
        XCTAssertEqual(vm.recentLabels, ["cloud1", "local"])
    }

    func testMergeUbiquitousAppendsNewEntries() {
        let store = InMemoryUbiquitousStore()
        let suite = "RecentLabelsMerge-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(["local"], forKey: "recentLabels")

        let vm = makeViewModel(ubiStore: store, userDefaults: defaults, defaultsSuite: suite)
        store.set(["cloudA", "cloudB"], forKey: "recentLabels")

        vm.mergeUbiquitous()
        XCTAssertEqual(vm.recentLabels, ["local", "cloudA", "cloudB"])
        XCTAssertEqual(defaults.array(forKey: "recentLabels") as? [String], ["local", "cloudA", "cloudB"])
    }

    func testAddRecentLabelDeduplicatesAndCaps() {
        let vm = makeViewModel()
        for index in 0..<12 {
            vm.addRecentLabel("label-\(index)")
        }
        vm.addRecentLabel("label-5")
        XCTAssertEqual(vm.recentLabels.first, "label-5")
        XCTAssertEqual(vm.recentLabels.count, 10)
    }

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

    private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
        #if os(macOS)
        return defaultsSuite(for: defaults) ?? ""
        #else
        return ""
        #endif
    }

    #if os(macOS)
    private func defaultsSuite(for defaults: UserDefaults) -> String? {
        defaults.dictionaryRepresentation()["suiteName"] as? String
    }
    #endif
}
