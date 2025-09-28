import XCTest
@testable import FidoPassApp

final class SecurePinVaultTests: XCTestCase {
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
