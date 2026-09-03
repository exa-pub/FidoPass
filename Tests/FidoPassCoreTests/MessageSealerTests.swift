import XCTest
import CryptoKit
@testable import FidoPassCore

/// Messages outlive the build that sealed them: whatever is written today has to open years
/// from now. The construction is therefore pinned three ways — against RFC 9180's own vector
/// for the ciphersuite, against a message frozen here, and by the properties every AEAD
/// has to have.
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
        let otherScalar = try MessageFixtures.key(scalar: Data(repeating: 0x42, count: 32))
        XCTAssertThrowsError(try sealer.open(sealed, with: otherScalar)) { error in
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

    /// RFC 9180 Appendix A.2 — DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20Poly1305,
    /// base mode, encryption 0. Pins that `MessageSealer.ciphersuite` is exactly that suite.
    func testRecipientMatchesTheRFC9180Vector() throws {
        let recipientKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(hexString: "8057991eef8f1f1af18f4a9491d16a1ce333f695d4db8e38da75975c4478e0fb"))
        let enc = Data(hexString: "1afa08d3dec047a643885163f1180476fa7ddb54c6a8029ea33f95796bf2ac4a")
        let info = Data(hexString: "4f6465206f6e2061204772656369616e2055726e")
        let aad = Data(hexString: "436f756e742d30")
        let ciphertext = Data(hexString: "1c5250d8034ec2b784ba2cfd69dbdb8af406cfe3ff938e131f0def8c8b60b4db21993c62ce81883d2dd1b51a28")

        var recipient = try HPKE.Recipient(privateKey: recipientKey,
                                           ciphersuite: MessageSealer.ciphersuite,
                                           info: info,
                                           encapsulatedKey: enc)
        let plaintext = try recipient.open(ciphertext, authenticating: aad)
        XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), "Beauty is truth, truth beauty")
    }

    /// A message sealed by this build, frozen. If it stops opening, messages in the wild
    /// have become unreadable — and the change is wrong unless it ships as `blobv2`.
    func testFrozenMessageOpens() throws {
        let key = try MessageFixtures.key()
        let sealed = try SealedMessageURL(parsing: Self.frozenMessage)
        XCTAssertEqual(try sealer.open(sealed, with: key), "frozen on 2026-09-03 — do not thaw")
    }

    func testInfoBindsTheKeyToTheMessage() throws {
        let url = try MessageFixtures.url()
        let info = MessageSealer.info(nonce: url.nonce, locator: url.locator)
        XCTAssertEqual(info.prefix(MessageSealer.domain.count), MessageSealer.domain)
        XCTAssertEqual(info.count, MessageSealer.domain.count + 32 + 16)
        XCTAssertEqual(String(decoding: MessageSealer.domain, as: UTF8.self), "fidopass|ecies|blob|v1")
    }

    static let frozenMessage = "fidopass://blobv1?nonce=AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw&idfp=y1iDTfGICAGYgZL2iQdGMQ&content=uDRoThkKoW8ps_KvFuVI2FRbiMiHre5e59XbGKvg1ywUQGkaGpCRVs_lN6I2ht1QvLFGXjY7f-U5wNXtHaLLiywR50j3fl-brJ_79rIjdiRNLFHh"
}
