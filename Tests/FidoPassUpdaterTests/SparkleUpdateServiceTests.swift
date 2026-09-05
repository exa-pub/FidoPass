import XCTest
@testable import FidoPassUpdater

/// The service in a bundle that carries no feed — every build but a signed release.
@MainActor
final class SparkleUpdateServiceTests: XCTestCase {

    func testABundleWithoutAFeedStaysInert() {
        let bundle = Bundle(for: SparkleUpdateServiceTests.self)
        XCTAssertNil(bundle.object(forInfoDictionaryKey: "SUFeedURL"), "the test bundle must not look like a release")
        let service = SparkleUpdateService(bundle: bundle, defaults: UserDefaults(suiteName: "SparkleUpdateServiceTests")!)

        XCTAssertFalse(service.isAvailable)
        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.lastCheck)
        XCTAssertFalse(service.automaticallyChecks)

        service.automaticallyChecks = true
        service.checkForUpdates()
        service.install()
        service.relaunchGateDidOpen()
        XCTAssertEqual(service.state, .idle, "nothing may happen without an updater")
        XCTAssertFalse(service.automaticallyChecks, "there is no updater to remember the setting")
    }
}
