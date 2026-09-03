import XCTest
@testable import FidoPassCore

final class AccountLocatorTests: XCTestCase {

    /// Frozen: a locator that changed would leave every message ever sealed unable to find
    /// its account.
    func testVectorIsFrozen() throws {
        let locator = try AccountLocator.compute(nonce: MessageFixtures.nonce, identity: MessageFixtures.identity)
        XCTAssertEqual(locator.bytes.count, AccountLocator.byteCount)
        XCTAssertEqual(locator.bytes.hexString, Self.frozenHex)
    }

    func testNonceAndIdentityBothMatter() throws {
        let base = try AccountLocator.compute(nonce: MessageFixtures.nonce, identity: MessageFixtures.identity)
        let otherNonce = try AccountLocator.compute(nonce: MessageFixtures.otherNonce, identity: MessageFixtures.identity)
        let otherIdentity = try AccountLocator.compute(nonce: MessageFixtures.nonce,
                                                       identity: AccountIdentity(hex: "0c0b0a090807060504030201")!)
        XCTAssertNotEqual(base, otherNonce)
        XCTAssertNotEqual(base, otherIdentity)
        XCTAssertEqual(base, try AccountLocator.compute(nonce: MessageFixtures.nonce, identity: MessageFixtures.identity),
                       "deterministic — the receiving side recomputes it")
    }

    /// The locator and the private scalar share the nonce as their salt; the domain prefix
    /// in the password is what keeps them apart.
    func testDomainIsDistinctFromTheKeyDerivationDomain() {
        XCTAssertEqual(String(decoding: AccountLocator.domain, as: UTF8.self), "fidopass|ecies|idfp|v1")
        XCTAssertNotEqual(AccountLocator.domain, MessageKeyService.scalarDomain)
    }

    func testWrongNonceLengthIsRefused() {
        XCTAssertThrowsError(try AccountLocator.compute(nonce: Data(repeating: 1, count: 16), identity: MessageFixtures.identity))
        XCTAssertNil(AccountLocator(bytes: Data(repeating: 1, count: 12)))
    }

    static let frozenHex = "cb58834df1880801988192f689074631"
}
