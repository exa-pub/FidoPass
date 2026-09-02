import XCTest
import CryptoKit
@testable import FidoPassCore
import TestSupport

/// Encrypted values outlive the build that produced them: whatever is written today has to
/// open years from now. The envelope format and the key derivation are therefore pinned the
/// same way password derivation is — if these fail, previously encrypted data has become
/// unreadable, and the change is wrong unless it ships under a new format version.
final class SecretEncryptionTests: XCTestCase {

    private let secret = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 5) })
    private let fixedNonceBytes = Data((0..<12).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 3) })

    private func makeService() -> SecretEncryptionService {
        SecretEncryptionService(secretDerivationService: MockSecretDerivationService())
    }

    private func makeKey(from source: Data? = nil) -> EncryptionKey {
        EncryptionKey(material: SecretEncryptionService.deriveKeyMaterial(from: source ?? secret))
    }

    // MARK: - Frozen outputs

    func testKeyDerivationIsPinned() {
        let raw = SecretEncryptionService.deriveKeyMaterial(from: secret).withUnsafeBytes { Data($0) }
        XCTAssertEqual(raw.map { String(format: "%02x", $0) }.joined(),
                       "ec9621f3b6b74bfa7dfd51a37bb18b6bfaed391bddbd24d4a6f733372e2354a8")
    }

    /// The encryption key must not be reachable from the password derived off the same
    /// authenticator secret. The password gets pasted into other applications; if one
    /// yielded the other, disclosing a password would disclose every encrypted value.
    func testEncryptionKeyIsIndependentOfPasswordMaterial() {
        let aes = SecretEncryptionService.deriveKeyMaterial(from: secret).withUnsafeBytes { Data($0) }
        let password = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                                              salt: Data("pw-map".utf8),
                                              info: Data("fidopass|pw|v1".utf8),
                                              outputByteCount: 32).withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(aes, password)
        XCTAssertEqual(password.map { String(format: "%02x", $0) }.joined(),
                       "3bb2ae8ae2a7b8dfee07115f85c38b15dbe0393bda706d20f992616e10d28a42",
                       "password derivation must not drift either — it is what this is separated from")
    }

    func testEnvelopeVectorsAreFrozen() throws {
        let service = makeService()
        let key = makeKey()
        let nonce = try AES.GCM.Nonce(data: fixedNonceBytes)
        let vectors: [(text: String, expected: String)] = [
            ("", "RlBFMQEBAxQlNkdYaXqLnK2+TDFDMhs5iUAU4YEnOFwk6A=="),
            ("hello", "RlBFMQEBAxQlNkdYaXqLnK2+AqSvd0dLf9FFNq9we4REsVTxAap4"),
            ("пароль 🔐", "RlBFMQEBAxQlNkdYaXqLnK2+un4Tq/nCtssqFQRE024+y9zWIfO0Hw7QGklcmozH9fvP")
        ]
        for vector in vectors {
            XCTAssertEqual(try service.seal(vector.text, with: key, nonce: nonce), vector.expected,
                           "envelope for “\(vector.text)” changed")
        }
    }

    // MARK: - Round trip

    func testRoundTrip() throws {
        let service = makeService()
        let key = makeKey()
        let samples = [
            "",
            "hello",
            "пароль с пробелами",
            "🔐🗝️ emoji only",
            "line\nbreak\ttab",
            "null\u{0}inside",
            String(repeating: "x", count: 10_000)
        ]
        for sample in samples {
            let sealed = try service.seal(sample, with: key)
            XCTAssertEqual(try service.open(sealed, with: key), sample)
        }
    }

    func testEmptyInputOpensToEmptyString() throws {
        XCTAssertEqual(try makeService().open("   ", with: makeKey()), "")
    }

    /// Values are frequently pasted back after being wrapped by another application.
    func testWhitespaceInsideBase64IsTolerated() throws {
        let service = makeService()
        let key = makeKey()
        let sealed = try service.seal("wrapped", with: key)
        let wrapped = stride(from: 0, to: sealed.count, by: 20).map { offset -> String in
            let start = sealed.index(sealed.startIndex, offsetBy: offset)
            let end = sealed.index(start, offsetBy: min(20, sealed.count - offset))
            return String(sealed[start..<end])
        }.joined(separator: "\n")
        XCTAssertEqual(try service.open(wrapped, with: key), "wrapped")
    }

    // MARK: - Nonce handling

    /// A fixed nonce would be the single most damaging shortcut available here: reusing one
    /// across different plaintexts under the same key breaks confidentiality and lets an
    /// attacker forge values. The visible cost is that the output changes on every edit.
    func testEachSealProducesADifferentValue() throws {
        let service = makeService()
        let key = makeKey()
        let outputs = try (0..<20).map { _ in try service.seal("same text", with: key) }
        XCTAssertEqual(Set(outputs).count, outputs.count, "a repeated nonce would show up as a repeated value")
    }

    /// Nothing beyond the fixed header may be shared between two values encrypted with the
    /// same key: the envelope carries no key fingerprint precisely so that stored values
    /// cannot be linked to each other.
    func testValuesUnderTheSameKeyAreNotLinkable() throws {
        let service = makeService()
        let key = makeKey()
        let first = try XCTUnwrap(Data(base64Encoded: try service.seal("secret", with: key)))
        let second = try XCTUnwrap(Data(base64Encoded: try service.seal("secret", with: key)))

        let headerSize = CryptoEnvelope.headerSize
        XCTAssertEqual(first.prefix(headerSize), second.prefix(headerSize), "the header is meant to be identical")
        XCTAssertNotEqual(first.dropFirst(headerSize), second.dropFirst(headerSize),
                          "everything after the header must differ")
    }

    // MARK: - Rejection

    func testWrongKeyIsRejected() throws {
        let service = makeService()
        let sealed = try service.seal("secret", with: makeKey())
        let otherKey = makeKey(from: Data(repeating: 0x42, count: 32))
        XCTAssertThrowsError(try service.open(sealed, with: otherKey)) { error in
            // Indistinguishable from tampering by design — see testValuesUnderTheSameKeyAreNotLinkable.
            XCTAssertEqual(error as? SecretCryptoError, .authenticationFailed)
        }
    }

    func testFlippingAnyByteIsDetected() throws {
        let service = makeService()
        let key = makeKey()
        let raw = try XCTUnwrap(Data(base64Encoded: try service.seal("tamper me", with: key)))

        for index in raw.indices {
            var mutated = raw
            mutated[index] ^= 0x01
            guard mutated != raw else { continue }
            XCTAssertThrowsError(try service.open(mutated.base64EncodedString(), with: key),
                                 "flipping byte \(index) went undetected")
        }
    }

    func testTruncationIsDetected() throws {
        let service = makeService()
        let key = makeKey()
        let raw = try XCTUnwrap(Data(base64Encoded: try service.seal("truncate me", with: key)))
        for dropped in 1...8 {
            XCTAssertThrowsError(try service.open(raw.dropLast(dropped).base64EncodedString(), with: key))
        }
    }

    func testNonBase64IsReportedAsIncompleteRatherThanBroken() {
        XCTAssertThrowsError(try makeService().open("not base64 !!!", with: makeKey())) { error in
            XCTAssertEqual(error as? SecretCryptoError, .notBase64)
        }
    }

    func testForeignBase64IsRecognisedAsNotOurs() {
        let foreign = Data(repeating: 0xAB, count: 64).base64EncodedString()
        XCTAssertThrowsError(try makeService().open(foreign, with: makeKey())) { error in
            XCTAssertEqual(error as? SecretCryptoError, .notFidoPassEnvelope)
        }
    }

    func testTooShortToBeAnEnvelope() {
        let short = Data("FPE1".utf8).base64EncodedString()
        XCTAssertThrowsError(try makeService().open(short, with: makeKey())) { error in
            XCTAssertEqual(error as? SecretCryptoError, .notFidoPassEnvelope)
        }
    }

    func testNewerFormatVersionIsNamedRatherThanGuessed() throws {
        let service = makeService()
        let key = makeKey()
        var raw = try XCTUnwrap(Data(base64Encoded: try service.seal("future", with: key)))
        raw[raw.startIndex + 4] = 99
        XCTAssertThrowsError(try service.open(raw.base64EncodedString(), with: key)) { error in
            XCTAssertEqual(error as? SecretCryptoError, .unsupportedVersion(99))
        }
    }

    func testOversizedPlaintextIsRefused() {
        let huge = String(repeating: "a", count: SecretCrypto.maxPlaintextCharacters + 1)
        XCTAssertThrowsError(try makeService().seal(huge, with: makeKey())) { error in
            XCTAssertEqual(error as? SecretCryptoError,
                           .tooLarge(limit: SecretCrypto.maxPlaintextCharacters))
        }
    }

    // MARK: - Key lifetime

    func testWipedKeyCannotBeUsed() throws {
        let service = makeService()
        var key = makeKey()
        let sealed = try service.seal("before", with: key)

        key.wipe()
        XCTAssertFalse(key.isUsable)
        XCTAssertThrowsError(try service.seal("after", with: key))
        XCTAssertThrowsError(try service.open(sealed, with: key))
    }

    func testDerivationGoesThroughTheAuthenticator() throws {
        let derivation = MockSecretDerivationService()
        derivation.deriveSecretClosure = { account, label, requireUV, _ in
            XCTAssertEqual(account.id, "vault")
            XCTAssertEqual(label, "notes")
            XCTAssertTrue(requireUV)
            return self.secret
        }
        let service = SecretEncryptionService(secretDerivationService: derivation)
        _ = try service.deriveEncryptionKey(account: Account.fixture(id: "vault"),
                                            label: "notes",
                                            requireUV: true,
                                            pinProvider: nil)
        XCTAssertEqual(derivation.deriveSecretCalls.count, 1, "one touch per editing session, not per keystroke")
    }

    /// Label and account are part of the key, so a value encrypted under one pair must not
    /// open under another.
    func testDifferentLabelYieldsADifferentKey() throws {
        let derivation = MockSecretDerivationService()
        derivation.deriveSecretClosure = { _, label, _, _ in Data(SHA256.hash(data: Data(label.utf8))) }
        let service = SecretEncryptionService(secretDerivationService: derivation)
        let account = Account.fixture(id: "vault")

        let notesKey = try service.deriveEncryptionKey(account: account, label: "notes", requireUV: true, pinProvider: nil)
        let seedKey = try service.deriveEncryptionKey(account: account, label: "seed", requireUV: true, pinProvider: nil)

        let sealed = try service.seal("under notes", with: notesKey)
        XCTAssertEqual(try service.open(sealed, with: notesKey), "under notes")
        XCTAssertThrowsError(try service.open(sealed, with: seedKey))
    }
}
