import XCTest
import CryptoKit
@testable import FidoPassCore

/// `DeriveKeyPair` against RFC 9180's own vectors. The key pair behind every link is this
/// function of the argon2id output; if it drifts, every key ever issued stops opening its
/// messages — and a browser page with a standard HPKE library stops agreeing with the app.
final class DHKEMTests: XCTestCase {

    /// Appendix A.1 — DHKEM(X25519, HKDF-SHA256), the recipient.
    func testRecipientKeyPairMatchesRFC9180A1() throws {
        let pair = try DHKEM.deriveKeyPair(ikm: Data(hexString: "6db9df30aa07dd42ee5e8181afdb977e538f5e1fec8a06223f33f7013e525037"))
        XCTAssertEqual(pair.privateKey.hexString, "4612c550263fc8ad58375df3f557aac531d26850903e55a9f23f21d8534e8ac8")
        XCTAssertEqual(pair.publicKey.hexString, "3948cfe0ad1ddb695d780e59077195da6c56506b027329794ab02bca80815c4d")
    }

    /// Appendix A.1 — the ephemeral pair, the same function.
    func testEphemeralKeyPairMatchesRFC9180A1() throws {
        let pair = try DHKEM.deriveKeyPair(ikm: Data(hexString: "7268600d403fce431561aef583ee1613527cff655c1343f29812e66706df3234"))
        XCTAssertEqual(pair.privateKey.hexString, "52c4a758a802cd8b936eceea314432798d5baf2d7e9235dc084ab1b9cfa2f736")
        XCTAssertEqual(pair.publicKey.hexString, "37fda3567bdbd628e88668c3c8d7e97d1d1253b6d4ea6d44c150f741f1bf4431")
    }

    /// Appendix A.2 shares the KEM. Its `skRm` has bit 255 set — it is not clamped — and
    /// still yields the RFC's `pkRm`: X25519 clamps at use, so no clamping belongs in the
    /// format, and none happens here.
    func testKeyPairMatchesRFC9180A2AndNeedsNoClamping() throws {
        let pair = try DHKEM.deriveKeyPair(ikm: Data(hexString: "1ac01f181fdf9f352797655161c58b75c656a6cc2716dcb66372da835542e1df"))
        XCTAssertEqual(pair.privateKey.hexString, "8057991eef8f1f1af18f4a9491d16a1ce333f695d4db8e38da75975c4478e0fb")
        XCTAssertEqual(pair.publicKey.hexString, "4310ee97d88cc1f088a5576c77ab0cf5c3ac797f3d95139c6c84b5429c59662a")
        XCTAssertEqual(pair.privateKey[31] & 0x80, 0x80, "the RFC's private key is unclamped")
        XCTAssertEqual(try MessageKey.publicKey(for: pair.privateKey), pair.publicKey)
    }

    /// `LabeledExtract("", …)` is HKDF-Extract with an empty salt, which RFC 5869 defines as
    /// HMAC under a key of hash-length zeros. CryptoKit does that with `Data()`; this pins
    /// it, because the RFC vectors above would be the only other thing to notice.
    func testEmptySaltExtractIsHMACUnderAZeroKey() throws {
        let ikm = Data(hexString: "6db9df30aa07dd42ee5e8181afdb977e538f5e1fec8a06223f33f7013e525037")
        let labeled = Data("HPKE-v1".utf8) + Data("KEM".utf8) + Data([0x00, 0x20]) + Data("dkp_prk".utf8) + ikm
        let manual = HMAC<SHA256>.authenticationCode(for: labeled, using: SymmetricKey(data: Data(repeating: 0, count: 32)))
        XCTAssertEqual(Data(DHKEM.labeledExtract(salt: Data(), label: "dkp_prk", ikm: ikm)), Data(manual))
    }

    func testInputMustBeThirtyTwoBytes() {
        XCTAssertThrowsError(try DHKEM.deriveKeyPair(ikm: Data(repeating: 1, count: 16)))
        XCTAssertThrowsError(try DHKEM.deriveKeyPair(ikm: Data(repeating: 1, count: 64)))
        XCTAssertNoThrow(try DHKEM.deriveKeyPair(ikm: Data(repeating: 1, count: 32)))
    }

    func testDeterministicAndSensitiveToEveryBit() throws {
        let ikm = Data(repeating: 0x5a, count: 32)
        let first = try DHKEM.deriveKeyPair(ikm: ikm)
        let second = try DHKEM.deriveKeyPair(ikm: ikm)
        XCTAssertEqual(first.privateKey, second.privateKey)
        XCTAssertEqual(first.publicKey, second.publicKey)
        var flipped = ikm
        flipped[31] ^= 0x01
        XCTAssertNotEqual(try DHKEM.deriveKeyPair(ikm: flipped).publicKey, first.publicKey)
    }
}
