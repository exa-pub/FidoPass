import Foundation

public protocol SecretEncrypting: SecretCipher {
    /// Derives the encryption key for an account and label. Costs one touch of the
    /// authenticator, so callers hold the result for the length of an editing session.
    func deriveEncryptionKey(_ handle: AccountHandle,
                             label: String,
                             parameters: DerivationParameters,
                             pinProvider: (@Sendable () -> String?)?) throws -> EncryptionKey
}
