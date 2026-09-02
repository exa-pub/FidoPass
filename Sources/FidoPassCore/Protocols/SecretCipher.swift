import Foundation

/// Sealing and opening text under a key the authenticator derived.
///
/// Pure computation: no device is involved once the key exists. The text editor holds one
/// of these for the length of a session and nothing else of the core.
public protocol SecretCipher: Sendable {
    /// Encrypts text and returns a base64 envelope.
    ///
    /// Every call produces a different result for the same input: AES-GCM requires a fresh
    /// nonce, and reusing one across different plaintexts under the same key would break
    /// both confidentiality and authenticity.
    func seal(_ plaintext: String, with key: EncryptionKey) throws -> String

    func open(_ envelopeB64: String, with key: EncryptionKey) throws -> String
}
