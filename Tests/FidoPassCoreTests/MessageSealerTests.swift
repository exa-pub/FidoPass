import TestSupport
import XCTest
import CryptoKit
@testable import FidoPassCore

/// Messages outlive the build that sealed them: whatever is written today has to open years
/// from now. The construction is therefore pinned four ways — against RFC 9180's own vector
/// for the ciphersuite, against a message sealed by plain HPKE with the documented inputs,
/// against a message frozen here, and by the properties every AEAD has to have.
final class MessageSealerTests: XCTestCase {

    private let sealer = MessageSealer()

    // MARK: - Round trip

    func testRoundTrip() throws {
        let url = try MessageFixtures.url()
        let key = try MessageFixtures.key()
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
            let sealed = try sealer.seal(sample, for: url)
            XCTAssertEqual(try sealer.open(sealed, with: key), sample)
            XCTAssertEqual(try sealer.open(try SealedMessageURL(parsing: sealed.absoluteString), with: key), sample,
                           "and through its link")
        }
    }

    /// A fresh ephemeral key per message: the same text never seals to the same link.
    func testEachSealProducesADifferentMessage() throws {
        let url = try MessageFixtures.url()
        let outputs = try (0..<20).map { _ in try sealer.seal("same text", for: url).absoluteString }
        XCTAssertEqual(Set(outputs).count, outputs.count)
    }

    // MARK: - Rejection

    func testWrongKeyIsRejected() throws {
        let sealed = try sealer.seal("secret", for: try MessageFixtures.url())
        let otherKey = try MessageFixtures.key(privateKey: Data(repeating: 0x42, count: 32))
        XCTAssertThrowsError(try sealer.open(sealed, with: otherKey)) { error in
            XCTAssertEqual(error as? MessageCryptoError, .authenticationFailed)
        }
        let otherNonce = try MessageFixtures.key(nonce: MessageFixtures.otherNonce)
        XCTAssertThrowsError(try sealer.open(sealed, with: otherNonce)) { error in
            XCTAssertEqual(error as? MessageCryptoError, .authenticationFailed, "a key for another nonce")
        }
    }

    func testFlippingAnyByteIsDetected() throws {
        let key = try MessageFixtures.key()
        let sealed = try sealer.seal("tamper me", for: key.url)
        for index in sealed.content.indices {
            var mutated = sealed.content
            mutated[index] ^= 0x01
            let damaged = try SealedMessageURL(nonce: sealed.nonce, locator: sealed.locator, content: mutated)
            XCTAssertThrowsError(try sealer.open(damaged, with: key), "flipping byte \(index) went undetected")
        }
    }

    func testTruncationIsDetected() throws {
        let key = try MessageFixtures.key()
        let sealed = try sealer.seal("truncate me, please", for: key.url)
        for dropped in 1...8 {
            let truncated = try SealedMessageURL(nonce: sealed.nonce,
                                                 locator: sealed.locator,
                                                 content: sealed.content.dropLast(dropped))
            XCTAssertThrowsError(try sealer.open(truncated, with: key))
        }
    }

    func testOversizedPlaintextIsRefused() throws {
        let huge = String(repeating: "a", count: MessageLimits.maxPlaintextCharacters + 1)
        XCTAssertThrowsError(try sealer.seal(huge, for: try MessageFixtures.url())) { error in
            XCTAssertEqual(error as? MessageCryptoError, .tooLarge(limit: MessageLimits.maxPlaintextCharacters))
        }
    }

    func testWipedKeyCannotOpen() throws {
        var key = try MessageFixtures.key()
        let sealed = try sealer.seal("before", for: key.url)
        key.wipe()
        XCTAssertFalse(key.isUsable)
        XCTAssertThrowsError(try sealer.open(sealed, with: key))
    }

    // MARK: - The construction itself

    /// RFC 9180 Appendix A.1 — DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, AES-128-GCM, base
    /// mode, encryption 0 — end to end: the recipient's key pair from the RFC's `ikmR`
    /// through `DHKEM`, then the RFC's ciphertext through `MessageSealer.ciphersuite`. Pins
    /// that the suite is exactly that one and that the key pair is the RFC's.
    func testRecipientMatchesTheRFC9180Vector() throws {
        let pair = try DHKEM.deriveKeyPair(ikm: Data(hexString: "6db9df30aa07dd42ee5e8181afdb977e538f5e1fec8a06223f33f7013e525037"))
        XCTAssertEqual(pair.publicKey.hexString, "3948cfe0ad1ddb695d780e59077195da6c56506b027329794ab02bca80815c4d")
        let enc = Data(hexString: "37fda3567bdbd628e88668c3c8d7e97d1d1253b6d4ea6d44c150f741f1bf4431")
        let info = Data(hexString: "4f6465206f6e2061204772656369616e2055726e")
        let aad = Data(hexString: "436f756e742d30")
        let ciphertext = Data(hexString: "f938558b5d72f1a23810b4be2ab4f84331acc02fc97babc53a52ae8218a355a96d8770ac83d07bea87e13c512a")

        var recipient = try HPKE.Recipient(privateKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: pair.privateKey),
                                           ciphersuite: MessageSealer.ciphersuite,
                                           info: info,
                                           encapsulatedKey: enc)
        let plaintext = try recipient.open(ciphertext, authenticating: aad)
        XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), "Beauty is truth, truth beauty")
    }

    /// What another implementation has to do to seal for us: HPKE base mode under the link's
    /// public key, `info` as documented, no `aad`, `enc ‖ ct` as content. Driven through
    /// CryptoKit directly rather than through `MessageSealer`, so that the inputs are the
    /// documented ones and nothing else.
    func testAMessageSealedWithPlainHPKEOpens() throws {
        let key = try MessageFixtures.key()
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: key.url.publicKey)
        let info = MessageSealer.domain + key.url.nonce + key.url.locator.bytes
        var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: MessageSealer.ciphersuite, info: info)
        let ciphertext = try sender.seal(Data("from elsewhere".utf8))

        let message = try SealedMessageURL(nonce: key.url.nonce,
                                           locator: key.url.locator,
                                           content: sender.encapsulatedKey + ciphertext)
        XCTAssertEqual(try sealer.open(message, with: key), "from elsewhere")
        XCTAssertEqual(message.content.count, 32 + "from elsewhere".utf8.count + 16)
    }

    /// A message sealed by this build, frozen. If it stops opening, messages in the wild
    /// have become unreadable — and the change is wrong unless it ships as `hpkeblobv2`.
    func testFrozenMessageOpens() throws {
        let key = try MessageFixtures.key()
        let sealed = try SealedMessageURL(parsing: Self.frozenMessage)
        XCTAssertEqual(try sealer.open(sealed, with: key), "frozen on 2026-09-04 — do not thaw")
    }

    /// `info` is the one binding of a message to its key: the nonce and the locator, behind
    /// the domain. A message sealed under an `info` for another locator does not open even
    /// when the link's own fields say it should.
    func testInfoBindsTheKeyToTheMessage() throws {
        let key = try MessageFixtures.key()
        let info = MessageSealer.info(nonce: key.url.nonce, locator: key.url.locator)
        XCTAssertEqual(info.prefix(MessageSealer.domain.count), MessageSealer.domain)
        XCTAssertEqual(info.count, MessageSealer.domain.count + 32 + 16)
        XCTAssertEqual(String(decoding: MessageSealer.domain, as: UTF8.self), "fidopass|hpke|info|v1")

        let otherLocator = try MessageFixtures.locator(nonce: MessageFixtures.otherNonce)
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: key.url.publicKey)
        var sender = try HPKE.Sender(recipientKey: recipient,
                                     ciphersuite: MessageSealer.ciphersuite,
                                     info: MessageSealer.info(nonce: key.url.nonce, locator: otherLocator))
        let ciphertext = try sender.seal(Data("misbound".utf8))
        let message = try SealedMessageURL(nonce: key.url.nonce,
                                           locator: key.url.locator,
                                           content: sender.encapsulatedKey + ciphertext)
        XCTAssertThrowsError(try sealer.open(message, with: key)) { error in
            XCTAssertEqual(error as? MessageCryptoError, .authenticationFailed)
        }
    }

    static let frozenMessage = "https://fidopass.org/link#hpkeblobv1?nonce=AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw&idfp=FZfcwcqV9GRF5jKRYBfPyQ&content=UYQyuFMtbgrHGFOfKywBJdW0z8Poem_7fLpZcrF_n1DqYOqz824Nv5Uj96quFjlFG3VolME-CFC1oSmUd3bODFIuEkauS815AMQgCEvaIbiNCKJR"
}

extension MessageSealerTests {
    func testCombiningScalarsCannotBypassPlaintextByteBudget() throws {
        let text = "a" + String(repeating: "\u{301}", count: MessageLimits.maxPlaintextBytes / 2)
        XCTAssertEqual(text.count, 1)
        let key = try MessageFixtures.url()
        XCTAssertThrowsError(try MessageSealer().seal(text, for: key))
    }
}
