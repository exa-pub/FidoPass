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
                                                       identity: AccountIdentity(hex: "0c0b0a09080706050403020100ffeedd")!)
        XCTAssertNotEqual(base, otherNonce)
        XCTAssertNotEqual(base, otherIdentity)
        XCTAssertEqual(base, try AccountLocator.compute(nonce: MessageFixtures.nonce, identity: MessageFixtures.identity),
                       "deterministic — the receiving side recomputes it")
    }

    /// The locator and the key material share the nonce as their salt; the domain prefix
    /// in the password is what keeps them apart — and apart from the HPKE `info`.
    func testDomainIsDistinctFromTheOtherMessageDomains() {
        XCTAssertEqual(String(decoding: AccountLocator.domain, as: UTF8.self), "fidopass|hpke|idfp|v1")
        XCTAssertNotEqual(AccountLocator.domain, MessageKeyService.ikmDomain)
        XCTAssertNotEqual(AccountLocator.domain, MessageSealer.domain)
        XCTAssertFalse(SaltFactory.messageSalt(nonce: MessageFixtures.nonce).starts(with: AccountLocator.domain))
    }

    func testWrongNonceLengthIsRefused() {
        XCTAssertThrowsError(try AccountLocator.compute(nonce: Data(repeating: 1, count: 16), identity: MessageFixtures.identity))
        XCTAssertNil(AccountLocator(bytes: Data(repeating: 1, count: 12)))
        XCTAssertNil(AccountLocator(bytes: Data(repeating: 1, count: 32)))
    }

    static let frozenHex = "1597dcc1ca95f46445e632916017cfc9"
}
