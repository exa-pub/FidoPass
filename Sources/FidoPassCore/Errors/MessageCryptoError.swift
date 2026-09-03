import Foundation

/// Why a key or a message could not be used.
///
/// The cases exist to be told apart in the UI. While someone is typing or pasting a link,
/// most intermediate states are simply incomplete — presenting those as failures would make
/// normal editing look broken — and the states that really are wrong say what to do about
/// them: ask for the link again, migrate the account, plug in the other key.
public enum MessageCryptoError: Error, Equatable, LocalizedError, Sendable {
    /// Not a whole link yet. The ordinary state of a field being typed into — and of a key
    /// link cut off before its checksum, which is required but looks exactly like that.
    case incomplete
    /// A link, but not one of ours — or one of ours that is not in canonical form.
    case notFidoPassURL
    /// One of ours, of the other kind: a key where a message was expected, or the reverse.
    case unexpectedKind(String)
    /// One of ours, written by a format this build does not know (`hpkev2`, say).
    case unsupportedVersion(String)
    /// The fingerprint in `keyfp` does not match the link — damaged in transit.
    case checksumMismatch
    /// The public key is not a usable X25519 point.
    case invalidPublicKey
    /// No account on the key derives this locator: the message is for another key or account.
    case noMatchingAccount
    /// The account has no identity yet; nothing is derived from it until it does.
    case accountNeedsMigration
    /// The message was not encrypted for this key, or it was altered. The two are
    /// indistinguishable by design.
    case authenticationFailed
    case tooLarge(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .incomplete:
            return "Waiting for a complete link"
        case .notFidoPassURL:
            return "Not a FidoPass link"
        case .unexpectedKind(let host):
            return host == EncryptionKeyURL.host ? "This is an encryption key, not a message" : "This is a message, not an encryption key"
        case .unsupportedVersion(let host):
            return "Written by a newer version of FidoPass (\(host))"
        case .checksumMismatch:
            return "The link was damaged in transit — ask for it again"
        case .invalidPublicKey:
            return "The key in this link is not usable"
        case .noMatchingAccount:
            return "No account on this key can open this message"
        case .accountNeedsMigration:
            return "This account needs to be migrated first"
        case .authenticationFailed:
            return "Wrong key, or the message was changed"
        case .tooLarge(let limit):
            return "Text is too long — the limit is \(limit) characters"
        }
    }
}
