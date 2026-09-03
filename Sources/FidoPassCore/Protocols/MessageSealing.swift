import Foundation

/// Sealing and opening messages, and the two computations the windows need before any key
/// is touched.
///
/// Pure computation: no device is involved. Sealing needs nothing but the key's link, which
/// is why the sending window is not bound to a key at all; opening needs a `MessageKey`,
/// which only `MessageKeyDeriving` can produce. `parseKey` and `locator` cost one argon2id
/// each (~10 ms, 32 MiB), so a window runs them off the main actor; a test may substitute
/// something cheaper.
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
