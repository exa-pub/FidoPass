import Foundation
import CryptoKit

/// An account's key for one nonce: the public link, and the private scalar behind it.
///
/// Deriving it costs a touch of the security key, so the receiving window keeps it alive for
/// as long as it is open rather than recomputing per message. A value type: the holder owns
/// the only copy, and `wipe()` makes the end of its life explicit instead of leaving the
/// material to be collected whenever.
///
/// One type for both uses. Issuing a key takes `url` and wipes the rest at once; opening
/// messages keeps it until the window closes. The scalar never leaves this module.
public struct MessageKey: Sendable {
    /// Everything public: nonce, public key, locator, fingerprint.
    public let url: EncryptionKeyURL
    /// Clamped X25519 scalar, 32 bytes; nil once wiped.
    private var scalar: Data?

    init(url: EncryptionKeyURL, scalar: Data) {
        precondition(scalar.count == 32, "an X25519 scalar is 32 bytes")
        self.url = url
        self.scalar = Self.clamp(scalar)
    }

    /// False once `wipe()` has been called; opening with it then fails.
    public var isUsable: Bool { scalar != nil }

    /// Drops the private material. Call when the window closes, the key locks, or the
    /// session locks.
    public mutating func wipe() {
        scalar = nil
    }

    func withPrivateKey<T>(_ body: (Curve25519.KeyAgreement.PrivateKey) throws -> T) throws -> T {
        guard let scalar else {
            throw FidoPassError.invalidState("The key is no longer available — reopen the window")
        }
        return try body(try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar))
    }

    /// RFC 7748 §5: clear the low three bits, clear the top bit, set the second-highest.
    ///
    /// Every X25519 implementation does this before multiplying; doing it here as well makes
    /// the public key a function of the bytes rather than of the implementation, and is
    /// idempotent.
    static func clamp(_ scalar: Data) -> Data {
        var clamped = Data(scalar)
        clamped[clamped.startIndex] &= 248
        clamped[clamped.startIndex + 31] &= 127
        clamped[clamped.startIndex + 31] |= 64
        return clamped
    }

    /// The public key for a scalar — what goes into the link.
    static func publicKey(for scalar: Data) throws -> Data {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: clamp(scalar)).publicKey.rawRepresentation
    }
}
