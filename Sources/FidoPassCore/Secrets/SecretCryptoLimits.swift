import Foundation

/// Limits the editor UI needs to know about without reaching into the service.
public enum SecretCrypto {
    /// Longest plaintext accepted for encryption.
    ///
    /// Both editor panes are ordinary text views; well before the crypto becomes a concern
    /// they stop being usable at all.
    public static let maxPlaintextCharacters = 65_536
}
