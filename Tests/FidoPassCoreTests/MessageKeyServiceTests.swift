import XCTest
import CryptoKit
@testable import FidoPassCore
import TestSupport

/// From the authenticator's answer to a key pair. The derivation is a contract like the
/// password one: `testFrozenVector` pins it, and the rest pins what goes in and what stays out.
final class MessageKeyServiceTests: XCTestCase {

    /// What the key answers an hmac-secret assertion with.
    private let answer = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 5) })
    private let fixed = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) })

    private func derivation() -> MockSecretDerivationService {
        let mock = MockSecretDerivationService()
        mock.deriveMessageSecretClosure = { [answer] _, _, _ in answer }
        mock.deriveFixedClosure = { [fixed] _, _ in fixed }
        return mock
    }

    /// The documented tail: argon2id over the raw secret, then RFC 9180 `DeriveKeyPair`.
    private func expectedPublicKey(secret: Data, nonce: Data) throws -> Data {
        let ikm = try Argon2.id(password: MessageKeyService.ikmDomain + secret,
                                salt: nonce,
                                parameters: .v1,
                                outputByteCount: 32)
        return try DHKEM.deriveKeyPair(ikm: ikm).publicKey
    }

    // MARK: - Local

    func testLocalKeyIsOneTouchUnderTheMessageNonce() throws {
        let mock = derivation()
        let service = MessageKeyService(secretDerivationService: mock)
        let key = try service.deriveMessageKey(AccountHandle.fixture(id: "vault"), nonce: MessageFixtures.nonce, pinProvider: nil)

        XCTAssertEqual(mock.deriveMessageSecretCalls.count, 1, "one touch per key")
        XCTAssertEqual(mock.deriveMessageSecretCalls.first?.1, MessageFixtures.nonce)
        XCTAssertTrue(mock.deriveSecretCalls.isEmpty, "the password path is not involved")
        XCTAssertTrue(mock.deriveFixedCalls.isEmpty)
        XCTAssertEqual(key.url.nonce, MessageFixtures.nonce)
        XCTAssertTrue(key.isUsable)
    }

    /// The key material is argon2id over the authenticator's raw answer — not a password,
    /// not anything `PasswordGenerator` would make of it — and the pair is `DeriveKeyPair`
    /// over that, nothing of our own in between.
    func testKeyPairIsDeriveKeyPairOverArgon2OfTheRawAnswer() throws {
        let service = MessageKeyService(secretDerivationService: derivation())
        let key = try service.deriveMessageKey(AccountHandle.fixture(id: "vault"), nonce: MessageFixtures.nonce, pinProvider: nil)

        XCTAssertEqual(key.url.publicKey, try expectedPublicKey(secret: answer, nonce: MessageFixtures.nonce))
        XCTAssertEqual(String(decoding: MessageKeyService.ikmDomain, as: UTF8.self), "fidopass|hpke|ikm|v1")
    }

    /// Frozen. A change here means every key ever issued stops opening its messages.
    func testFrozenVector() throws {
        let service = MessageKeyService(secretDerivationService: derivation())
        let local = try service.deriveMessageKey(AccountHandle.fixture(id: "vault"), nonce: MessageFixtures.nonce, pinProvider: nil)
        XCTAssertEqual(local.url.publicKey.hexString, Self.frozenLocalPublicKey)

        let portable = try service.deriveMessageKey(AccountHandle.portableFixture(id: "vault"), nonce: MessageFixtures.nonce, pinProvider: nil)
        XCTAssertEqual(portable.url.publicKey.hexString, Self.frozenPortablePublicKey)
    }

    // MARK: - Portable

    func testPortableKeyIsTheMasterKeyUnderTheMessageSalt() throws {
        let mock = derivation()
        let service = MessageKeyService(secretDerivationService: mock)
        let handle = AccountHandle.portableFixture(id: "vault")
        let key = try service.deriveMessageKey(handle, nonce: MessageFixtures.nonce, pinProvider: nil)

        XCTAssertEqual(mock.deriveFixedCalls.count, 1, "one touch, for the fixed component")
        XCTAssertTrue(mock.deriveMessageSecretCalls.isEmpty)

        let masterKey = PortableMasterKey.combine(fixed, handle.account.mask!)
        let secret = Data(HMAC<SHA256>.authenticationCode(for: SaltFactory.messageSalt(nonce: MessageFixtures.nonce),
                                                          using: SymmetricKey(data: masterKey)))
        XCTAssertEqual(key.url.publicKey, try expectedPublicKey(secret: secret, nonce: MessageFixtures.nonce))
    }

    /// The same account on a second key — same master key, different credential, possibly a
    /// different name — issues the same public key and finds itself by the same locator.
    func testABackupOfTheAccountIssuesTheSameKey() throws {
        let service = MessageKeyService(secretDerivationService: derivation())
        let original = AccountHandle.portableFixture(id: "vault", credentialId: Data("cred-A".utf8), devicePath: "/dev/a")
        let identity = original.account.identity!
        let copy = AccountHandle.portableFixture(id: "renamed", credentialId: Data("cred-B".utf8), identity: identity, devicePath: "/dev/b")

        let first = try service.deriveMessageKey(original, nonce: MessageFixtures.nonce, pinProvider: nil)
        let second = try service.deriveMessageKey(copy, nonce: MessageFixtures.nonce, pinProvider: nil)
        XCTAssertEqual(first.url, second.url)
    }

    /// The identity names the account and takes no part in the key: two accounts with the
    /// same mask and different identities issue the same public key — and different
    /// locators, which is the identity's only job here.
    func testIdentityAffectsOnlyTheLocator() throws {
        let service = MessageKeyService(secretDerivationService: derivation())
        let one = AccountHandle.portableFixture(id: "vault", identity: AccountIdentity(hex: "00000000000000000000000000000000"))
        let other = AccountHandle.portableFixture(id: "vault", identity: AccountIdentity(hex: "ffffffffffffffffffffffffffffffff"))

        let first = try service.deriveMessageKey(one, nonce: MessageFixtures.nonce, pinProvider: nil)
        let second = try service.deriveMessageKey(other, nonce: MessageFixtures.nonce, pinProvider: nil)
        XCTAssertEqual(first.url.publicKey, second.url.publicKey)
        XCTAssertNotEqual(first.url.locator, second.url.locator)
        XCTAssertNotEqual(first.url.fingerprint, second.url.fingerprint, "the locator is in the link, so the fingerprint differs")
    }

    // MARK: - Inputs that must matter, and gates

    func testDifferentNoncesGiveDifferentKeys() throws {
        let service = MessageKeyService(secretDerivationService: derivation())
        let handle = AccountHandle.fixture(id: "vault")
        let first = try service.deriveMessageKey(handle, nonce: MessageFixtures.nonce, pinProvider: nil)
        let second = try service.deriveMessageKey(handle, nonce: MessageFixtures.otherNonce, pinProvider: nil)
        XCTAssertNotEqual(first.url.publicKey, second.url.publicKey)
        XCTAssertNotEqual(first.url.locator, second.url.locator)
    }

    /// A portable v1 account has no identity, so no locator: refused until migrated.
    func testAnAccountWithoutAnIdentityIsRefusedBeforeTheKeyIsTouched() throws {
        let mock = derivation()
        let service = MessageKeyService(secretDerivationService: mock)
        XCTAssertThrowsError(try service.deriveMessageKey(AccountHandle.portableFixture(id: "old", legacy: true),
                                                         nonce: MessageFixtures.nonce,
                                                         pinProvider: nil)) { error in
            XCTAssertEqual(error as? MessageCryptoError, .accountNeedsMigration)
        }
        XCTAssertTrue(mock.deriveFixedCalls.isEmpty, "no touch is spent on a refused account")
    }

    func testWrongNonceLengthIsRefused() {
        let service = MessageKeyService(secretDerivationService: derivation())
        XCTAssertThrowsError(try service.deriveMessageKey(AccountHandle.fixture(id: "vault"),
                                                         nonce: Data(repeating: 1, count: 16),
                                                         pinProvider: nil))
    }

    func testAShortAnswerFromTheKeyIsRefused() {
        let mock = MockSecretDerivationService()
        mock.deriveMessageSecretClosure = { _, _, _ in Data(repeating: 1, count: 16) }
        let service = MessageKeyService(secretDerivationService: mock)
        XCTAssertThrowsError(try service.deriveMessageKey(AccountHandle.fixture(id: "vault"),
                                                         nonce: MessageFixtures.nonce,
                                                         pinProvider: nil))
    }

    // MARK: - Domains

    /// Nothing derived for a message shares a salt with anything derived for a password, in
    /// either format.
    func testMessageSaltsLiveInTheirOwnDomain() {
        let nonce = MessageFixtures.nonce
        let message = SaltFactory.messageSalt(nonce: nonce)
        XCTAssertNotEqual(message, SaltFactory.fixedComponentSalt())
        XCTAssertNotEqual(message, SaltFactory.fixedComponentSaltV2())
        for label in ["", "vault", nonce.base64EncodedString(), String(decoding: nonce, as: UTF8.self)] {
            XCTAssertNotEqual(message, SaltFactory.residentSalt(label: label, rpId: "fidopass.local", accountId: "vault", revision: 1))
            XCTAssertNotEqual(message, SaltFactory.residentSalt(label: label, rpId: "fidopass.portable", accountId: label, revision: 1))
            XCTAssertNotEqual(message, SaltFactory.localPasswordSalt(label: label, revision: 1))
            XCTAssertNotEqual(message, SaltFactory.portableLabelSalt(label))
        }
        XCTAssertNotEqual(message, SaltFactory.messageSalt(nonce: MessageFixtures.otherNonce))
    }

    static let frozenLocalPublicKey = "8c2338937e539280959bfaa628c3c0c97f0a9e8785a1da7605311eb063aa3a37"
    static let frozenPortablePublicKey = "49e537c146b4262205e6506859aae25403bd33198a949a80a3ca52d7b0849a0a"
}
