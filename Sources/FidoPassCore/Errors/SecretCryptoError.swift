import Foundation

/// Why a value could not be decrypted.
///
/// The cases exist to be told apart in the UI. While someone is typing or pasting into the
/// ciphertext field, most intermediate states are simply incomplete — presenting those as
/// failures would make normal editing look broken.
public enum SecretCryptoError: Error, Equatable, LocalizedError {
    /// Not valid base64 yet. The ordinary state of a field being typed into.
    case notBase64
    /// Decodes as base64, but is not a FidoPass value.
    case notFidoPassEnvelope
    /// A FidoPass value written by a newer format than this build understands.
    case unsupportedVersion(UInt8)
    /// A FidoPass value that failed its integrity check.
    ///
    /// Covers both "encrypted with a different key" and "the data was altered". The two are
    /// deliberately indistinguishable: the envelope carries no key fingerprint, so that two
    /// values cannot be linked to the same key by anyone who sees them.
    case authenticationFailed
    case tooLarge(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .notBase64:
            return "Waiting for a complete value"
        case .notFidoPassEnvelope:
            return "Not a FidoPass value"
        case .unsupportedVersion(let version):
            return "This value was written by a newer version of FidoPass (format \(version))"
        case .authenticationFailed:
            return "Wrong account or label, or the data was changed"
        case .tooLarge(let limit):
            return "Text is too long — the limit is \(limit) characters"
        }
    }
}
