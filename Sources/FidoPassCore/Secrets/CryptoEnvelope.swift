import Foundation

/// Wire format for an encrypted value, before base64.
///
/// ```
/// offset  size  field
/// 0       4     magic "FPE1"
/// 4       1     format version
/// 5       1     scheme id (AES-256-GCM over HKDF-SHA256)
/// 6       12    nonce
/// 18      …     ciphertext
/// end     16    GCM tag
/// ```
///
/// The header exists so the format can change later and so a value that is simply not ours
/// can be reported as such instead of as a decryption failure.
///
/// What the header deliberately does not carry: the account id, the label, or any
/// fingerprint of the key. Two values encrypted with the same key must not be linkable by
/// whoever stores them. The cost is that a wrong key and altered data both surface as one
/// failure — see `SecretCryptoError.authenticationFailed`.
///
/// The magic does identify FidoPass as the producer: every value starts with `RlBFM` once
/// base64-encoded. That is tool identity rather than key identity, and it is what makes
/// "not a FidoPass value" possible to say at all.
enum CryptoEnvelope {
    static let magic = Data("FPE1".utf8)
    static let version: UInt8 = 1
    static let schemeAESGCM: UInt8 = 1
    static let headerSize = 6
    static let nonceSize = 12
    static let tagSize = 16

    /// Smallest possible value: header plus nonce plus tag, with empty ciphertext.
    static var minimumSize: Int { headerSize + nonceSize + tagSize }

    static func encode(sealed: Data) -> Data {
        var out = Data(capacity: headerSize + sealed.count)
        out.append(magic)
        out.append(version)
        out.append(schemeAESGCM)
        out.append(sealed)
        return out
    }

    /// Splits a decoded value into its header and the sealed box that follows.
    static func decode(_ data: Data) throws -> Data {
        guard data.count >= minimumSize else {
            // Too short to be one of ours, whatever it is.
            throw SecretCryptoError.notFidoPassEnvelope
        }
        guard data.prefix(magic.count) == magic else {
            throw SecretCryptoError.notFidoPassEnvelope
        }
        let versionByte = data[data.startIndex + 4]
        let schemeByte = data[data.startIndex + 5]
        guard versionByte == version, schemeByte == schemeAESGCM else {
            throw SecretCryptoError.unsupportedVersion(versionByte)
        }
        return data.dropFirst(headerSize)
    }
}
