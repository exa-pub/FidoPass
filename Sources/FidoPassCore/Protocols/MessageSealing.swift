import Foundation

/// Device-independent message operations. Parsing fingerprints and computing locators
/// use Argon2id and must run off the main actor.
public protocol MessageSealing: Sendable {
    /// Seals text under a key. Every call produces a different link for the same input — a
    /// fresh ephemeral key is part of the construction.
    func seal(_ plaintext: String, for key: EncryptionKeyURL) throws -> SealedMessageURL

    /// Opens a message with the key its nonce was derived into.
    func open(_ message: SealedMessageURL, with key: MessageKey) throws -> String

    /// Reads a pasted key link, fingerprint check included.
    func parseKey(_ text: String) throws -> EncryptionKeyURL

    /// The locator an account would have under a nonce — how a message is matched to an
    /// account without asking the key anything.
    func locator(nonce: Data, identity: AccountIdentity) throws -> AccountLocator
}
