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

    /// The scalar is argon2id over the authenticator's raw answer — not a password, not
    /// anything `PasswordGenerator` would make of it.
    func testSecretIsTheRawAuthenticatorOutput() throws {
        let service = MessageKeyService(secretDerivationService: derivation())
        let key = try service.deriveMessageKey(AccountHandle.fixture(id: "vault"), nonce: MessageFixtures.nonce, pinProvider: nil)

        let scalar = try Argon2.id(password: MessageKeyService.scalarDomain + answer,
                                   salt: MessageFixtures.nonce,
                                   parameters: .v1,
                                   outputByteCount: 32)
        XCTAssertEqual(key.url.publicKey, try MessageKey.publicKey(for: scalar))
        XCTAssertEqual(String(decoding: MessageKeyService.scalarDomain, as: UTF8.self), "fidopass|ecies|x25519|v1")
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
        let secret = Data(HMAC<SHA256>.authenticationCode(for: SaltFactory.portableMessageSalt(nonce: MessageFixtures.nonce),
                                                          using: SymmetricKey(data: masterKey)))
        let scalar = try Argon2.id(password: MessageKeyService.scalarDomain + secret,
                                   salt: MessageFixtures.nonce,
                                   parameters: .v1,
                                   outputByteCount: 32)
        XCTAssertEqual(key.url.publicKey, try MessageKey.publicKey(for: scalar))
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

    /// Nothing derived for a message shares a salt with anything derived for a password.
    func testMessageSaltsLiveInTheirOwnDomain() {
        let nonce = MessageFixtures.nonce
        let message = SaltFactory.messageKeySalt(nonce: nonce)
        XCTAssertNotEqual(message, SaltFactory.fixedComponentSalt())
        XCTAssertNotEqual(message, SaltFactory.portableMessageSalt(nonce: nonce))
        for label in ["", "vault", nonce.base64EncodedString(), String(decoding: nonce, as: UTF8.self)] {
            XCTAssertNotEqual(message, SaltFactory.residentSalt(label: label, rpId: "fidopass.local", accountId: "vault", revision: 1))
            XCTAssertNotEqual(message, SaltFactory.residentSalt(label: label, rpId: "fidopass.portable", accountId: label, revision: 1))
            XCTAssertNotEqual(SaltFactory.portableMessageSalt(nonce: nonce), SaltFactory.portableLabelSalt(label))
        }
        XCTAssertNotEqual(SaltFactory.messageKeySalt(nonce: nonce), SaltFactory.messageKeySalt(nonce: MessageFixtures.otherNonce))
    }

    static let frozenLocalPublicKey = "75fc03ea2a26573484f1ee9741dc13e1c0aa3c7687a719569b9e33600e2b8634"
    static let frozenPortablePublicKey = "4c5ed442b9403db283783345b11d34bb1998a9303a290d103ea5aa44694baf1a"
}
