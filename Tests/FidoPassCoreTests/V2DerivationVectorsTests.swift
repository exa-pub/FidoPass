import XCTest
import CryptoKit
@testable import FidoPassCore
import TestSupport

/// The v2 derivations, pinned. What a v1 account derives is pinned by `GoldenVectorsTests`
/// and must never move; these are the same promise for the v2 layout — and the values a
/// browser page will have to reproduce, so they are written as plain hex.
///
/// The authenticator's answers are stubbed: what is pinned is everything the host does
/// with them, salts included.
final class V2DerivationVectorsTests: XCTestCase {

    /// What the key answers an hmac-secret assertion with, for the local password salt.
    private let answer = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 5) })
    /// What the key answers for the fixed component, in either format.
    private let fixed = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) })
    private let mask = Data((0..<32).map { UInt8(truncatingIfNeeded: 0xC3 &- $0) })
    private let identity = AccountIdentity(hex: "00112233445566778899aabbccddeeff")!

    private func derivation() -> MockSecretDerivationService {
        let mock = MockSecretDerivationService()
        mock.deriveSecretClosure = { [answer] _, _, _, _ in answer }
        mock.deriveFixedClosure = { [fixed] _, _ in fixed }
        mock.deriveMessageSecretClosure = { [answer] _, _, _ in answer }
        return mock
    }

    /// A v2 local account asks the key under the v2 salt and maps the answer through the
    /// unchanged policy-v1 tail.
    func testLocalPasswordIsPinned() throws {
        let mock = derivation()
        let generator = PasswordGenerator(secretDerivationService: mock)
        let account = AccountHandle.v2Fixture(id: "disk", kind: .local, identity: identity)

        let password = try generator.generatePassword(account, label: "vault", parameters: .v1, pinProvider: nil)

        XCTAssertEqual(mock.deriveSecretCalls.map { $0.1 }, ["vault"])
        XCTAssertEqual(password, "*KF<yShuz+5=y%*~TQKa")
    }

    /// A v2 portable account: master = fixed ⊕ mask, then the same HMAC-and-tail as v1.
    func testPortablePasswordIsPinned() throws {
        let generator = PasswordGenerator(secretDerivationService: derivation())
        let account = AccountHandle.v2Fixture(id: "vault", kind: .portable, identity: identity, mask: mask)

        let password = try generator.generatePassword(account, label: "vault", parameters: .v1, pinProvider: nil)
        XCTAssertEqual(password, "n+nQfBY!T_=Fh<m=S3#b")
    }

    /// The portable tail is format-independent: a v1 account with the same mask and the same
    /// fixed component derives the same password, which is what migration relies on.
    func testPortableTailIsFormatIndependent() throws {
        let generator = PasswordGenerator(secretDerivationService: derivation())
        let v1 = AccountHandle.fixture(id: "vault", kind: .portable, portable: PortablePayload(external: mask))
        let v2 = AccountHandle.v2Fixture(id: "vault", kind: .portable, identity: identity, mask: mask)
        XCTAssertEqual(try generator.generatePassword(v1, label: "vault", parameters: .v1, pinProvider: nil),
                       try generator.generatePassword(v2, label: "vault", parameters: .v1, pinProvider: nil))
    }

    /// The message key of a v2 portable account is the same as a v1 account's with the same
    /// master key — a key link issued before migration keeps opening messages after it.
    func testPortableMessageKeyIsPinnedAndFormatIndependent() throws {
        let service = MessageKeyService(secretDerivationService: derivation())
        let nonce = MessageFixtures.nonce
        let v2 = AccountHandle.v2Fixture(id: "vault", kind: .portable, identity: identity, mask: mask)
        let key = try service.deriveMessageKey(v2, nonce: nonce, pinProvider: nil)
        XCTAssertEqual(key.url.publicKey.hexString, "f5bfd00d18b227928b82e0405e45e8dd16a51a795935fce03d962ad81831db77")

        // The v1 account has no identity — no locator — so only the key pair can be compared.
        let v1Master = PortableMasterKey.combine(fixed, mask)
        let v1Secret = Data(HMAC<SHA256>.authenticationCode(for: SaltFactory.messageSalt(nonce: nonce), using: SymmetricKey(data: v1Master)))
        let v1Ikm = try Argon2.id(password: MessageKeyService.ikmDomain + v1Secret, salt: nonce, parameters: .v1, outputByteCount: 32)
        XCTAssertEqual(key.url.publicKey, try DHKEM.deriveKeyPair(ikm: v1Ikm).publicKey)
    }

    /// The v2 local message key: the raw answer under the message salt, then the frozen
    /// HPKE tail — argon2id and `DeriveKeyPair`.
    func testLocalMessageKeyIsPinned() throws {
        let mock = derivation()
        let service = MessageKeyService(secretDerivationService: mock)
        let account = AccountHandle.v2Fixture(id: "disk", kind: .local, identity: identity)
        let key = try service.deriveMessageKey(account, nonce: MessageFixtures.nonce, pinProvider: nil)
        XCTAssertEqual(mock.deriveMessageSecretCalls.count, 1)
        XCTAssertEqual(key.url.publicKey.hexString, "8c2338937e539280959bfaa628c3c0c97f0a9e8785a1da7605311eb063aa3a37")
        XCTAssertEqual(key.url.locator.bytes.hexString, "39d755fabbbb7d6ec99a54ff043bf9ab")
    }

    /// The salts the real derivation service would send to the key for these accounts.
    func testTheSaltsTheKeyIsAskedUnder() {
        XCTAssertEqual(SaltFactory.localPasswordSalt(label: "vault", revision: 1).hexString,
                       "346ef5e42fd931efdcfedc85cdbd31b3d1b5289e337c17a2dc604f8954419a7f")
        XCTAssertEqual(SaltFactory.fixedComponentSaltV2().hexString,
                       "5d267585fe91a12df6e27959f2be9e38fc12c0f55b4077826211f36b161af4fd")
        XCTAssertEqual(SaltFactory.messageSalt(nonce: MessageFixtures.nonce).hexString, "7e7abd979da6b556e7187e5fef573407579a800aaf4268c39c25dd33cb3a6ae3")
    }

    /// Nothing is derived from a credential without a usable record.
    func testAnIncompleteAccountDerivesNothing() {
        let mock = derivation()
        let generator = PasswordGenerator(secretDerivationService: mock)
        let keys = MessageKeyService(secretDerivationService: mock)
        for integrity in [AccountIntegrity.recordMissing, .recordCorrupt] {
            let account = AccountHandle.v2Fixture(id: "half", kind: .portable, identity: identity, integrity: integrity)
            XCTAssertThrowsError(try generator.generatePassword(account, label: "vault", parameters: .v1, pinProvider: nil))
            XCTAssertThrowsError(try keys.deriveMessageKey(account, nonce: MessageFixtures.nonce, pinProvider: nil))
        }
        XCTAssertTrue(mock.deriveSecretCalls.isEmpty)
        XCTAssertTrue(mock.deriveFixedCalls.isEmpty)
        XCTAssertTrue(mock.deriveMessageSecretCalls.isEmpty, "no touch is spent on a refused account")
    }
}
