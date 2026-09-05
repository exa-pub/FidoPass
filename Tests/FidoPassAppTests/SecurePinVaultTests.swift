import XCTest
@testable import FidoPassAppKit

final class SecurePinVaultTests: AppTestCase {
    func testPinStorageAndExpiration() {
        let expectation = expectation(description: "pin expired")
        let vault = SecurePinVault(defaultTTL: 0.05)
        let token = vault.store(pin: "1234", ttl: 0.05) {
            expectation.fulfill()
        }
        XCTAssertEqual(vault.pin(for: token), "1234")
        wait(for: [expectation], timeout: 1.0)
        XCTAssertNil(vault.pin(for: token))
    }

    func testPinExtensionDelaysExpiration() {
        let expireExpectation = expectation(description: "pin eventually expired")
        let vault = SecurePinVault(defaultTTL: 1.5)
        let token = vault.store(pin: "5678", ttl: 1.5) {
            expireExpectation.fulfill()
        }

        let extendExpectation = expectation(description: "pin extended")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(vault.pin(for: token, extending: 1.0), "5678")
            extendExpectation.fulfill()
        }

        wait(for: [extendExpectation], timeout: 2.0)
        XCTAssertEqual(vault.pin(for: token), "5678")

        wait(for: [expireExpectation], timeout: 4.0)
        XCTAssertNil(vault.pin(for: token))
    }
}

extension SecurePinVaultTests {
    func testOneFiveAndSixtyMinuteTimeoutsRestartAfterUse() {
        for ttl: TimeInterval in [60, 300, 3600] {
            let scheduler = ManualPinTimer()
            let vault = SecurePinVault(now: { scheduler.now }, timerFactory: { _, _, fire in scheduler.append(fire); return {} })
            let token = vault.store(pin: "1234", ttl: ttl)
            XCTAssertNotNil(vault.pin(for: token))
            scheduler.advance(ttl - 1)
            XCTAssertNotNil(vault.pin(for: token, extending: ttl))
            scheduler.advance(1)
            scheduler.fire(0)
            XCTAssertNotNil(vault.pin(for: token), "An old timer must not expire a session extended by use")
            scheduler.advance(ttl - 1)
            scheduler.fire(1)
            XCTAssertNil(vault.pin(for: token), "The configured inactivity interval must be respected")
        }
    }

    func testCancelledTimerDeliveryCannotExpireAnExtendedToken() {
        let scheduler = ManualPinTimer()
        let vault = SecurePinVault(now: { scheduler.now }, timerFactory: { _, _, fire in scheduler.append(fire); return {} })
        let token = vault.store(pin: "1234", ttl: 1)
        XCTAssertEqual(vault.pin(for: token, extending: 10), "1234")
        scheduler.advance(2)
        scheduler.fire(0) // A cancelled handler that was already queued.
        XCTAssertEqual(vault.pin(for: token), "1234")
        scheduler.advance(9)
        scheduler.fire(1)
        XCTAssertNil(vault.pin(for: token))
    }
}

/// All test clock state and callback captures are guarded by the lock.
private final class ManualPinTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_000)
    private var callbacks: [@Sendable () -> Void] = []
    var now: Date { lock.withLock { time } }
    func advance(_ interval: TimeInterval) { lock.withLock { time.addTimeInterval(interval) } }
    func append(_ fire: @escaping @Sendable () -> Void) { lock.withLock { callbacks.append(fire) } }
    func fire(_ index: Int) { lock.withLock { callbacks[index] }() }
}
