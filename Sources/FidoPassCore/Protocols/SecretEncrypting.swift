import Foundation

public protocol SecretEncrypting: SecretCipher {
    /// Derives the encryption key for an account and label. Costs one touch of the
    /// authenticator, so callers hold the result for the length of an editing session.
    func deriveEncryptionKey(account: Account,
                             label: String,
                             requireUV: Bool,
                             pinProvider: (@Sendable () -> String?)?) throws -> EncryptionKey
}
