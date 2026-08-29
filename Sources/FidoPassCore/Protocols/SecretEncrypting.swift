import Foundation

public protocol SecretEncrypting {
    /// Derives the encryption key for an account and label. Costs one touch of the
    /// authenticator, so callers hold the result for the length of an editing session.
    func deriveEncryptionKey(account: Account,
                             label: String,
                             requireUV: Bool,
                             pinProvider: (() -> String?)?) throws -> EncryptionKey

    /// Encrypts text and returns a base64 envelope.
    ///
    /// Every call produces a different result for the same input: AES-GCM requires a fresh
    /// nonce, and reusing one across different plaintexts under the same key would break
    /// both confidentiality and authenticity.
    func seal(_ plaintext: String, with key: EncryptionKey) throws -> String

    func open(_ envelopeB64: String, with key: EncryptionKey) throws -> String
}
