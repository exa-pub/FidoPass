import Foundation
import CryptoKit

/// RFC 9180 §7.1.3 DeriveKeyPair for X25519/HKDF-SHA256, absent from CryptoKit’s HPKE API.
/// Do not clamp sk here: X25519 clamps at use. RFC vectors pin the original bytes.
/// See docs/crypto.md §6.2 for the labelled HKDF construction.
enum DHKEM {
    static let inputKeyMaterialByteCount = 32
    static let privateKeyByteCount = 32

    struct KeyPair: Sendable {
        /// The raw scalar, exactly as `DeriveKeyPair` returns it.
        let privateKey: Data
        let publicKey: Data
    }

    private static let version = Data("HPKE-v1".utf8)
    /// `"KEM" ‖ I2OSP(kem_id, 2)`; `kem_id` 0x0020 is DHKEM(X25519, HKDF-SHA256).
    private static let suiteId = Data("KEM".utf8) + Data([0x00, 0x20])

    static func deriveKeyPair(ikm: Data) throws -> KeyPair {
        guard ikm.count == inputKeyMaterialByteCount else {
            throw FidoPassError.invalidState("HPKE key material must be \(inputKeyMaterialByteCount) bytes")
        }
        let prk = labeledExtract(salt: Data(), label: "dkp_prk", ikm: ikm)
        let privateKey = labeledExpand(prk: prk, label: "sk", info: Data(), outputByteCount: privateKeyByteCount)
        let publicKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey).publicKey.rawRepresentation
        return KeyPair(privateKey: privateKey, publicKey: publicKey)
    }

    /// `Extract(salt, "HPKE-v1" ‖ suite_id ‖ label ‖ ikm)`. An empty salt means HMAC under
    /// a key of hash-length zeros (RFC 5869), which is what CryptoKit does with `Data()`.
    static func labeledExtract(salt: Data, label: String, ikm: Data) -> HashedAuthenticationCode<SHA256> {
        HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: version + suiteId + Data(label.utf8) + ikm),
                             salt: salt)
    }

    /// `Expand(prk, I2OSP(L, 2) ‖ "HPKE-v1" ‖ suite_id ‖ label ‖ info, L)`.
    static func labeledExpand(prk: HashedAuthenticationCode<SHA256>,
                              label: String,
                              info: Data,
                              outputByteCount: Int) -> Data {
        let labeledInfo = Data([UInt8(outputByteCount >> 8), UInt8(outputByteCount & 0xff)])
            + version + suiteId + Data(label.utf8) + info
        return HKDF<SHA256>.expand(pseudoRandomKey: prk, info: labeledInfo, outputByteCount: outputByteCount)
            .withUnsafeBytes { Data($0) }
    }
}
