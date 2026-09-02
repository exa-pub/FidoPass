import Foundation
import CryptoKit

/// An AES key derived from the authenticator, held only in memory.
///
/// Deriving it costs a touch of the security key, so it is kept alive for as long as an
/// editing session lasts rather than recomputed per keystroke. A value type: the holder
/// owns the only copy, and `wipe()` makes the end of its life explicit instead of leaving
/// the material to be collected whenever.
///
/// The raw bytes are never exposed. Anything that needs them lives inside this module.
public struct EncryptionKey: Sendable {
    private var material: SymmetricKey?

    init(material: SymmetricKey) {
        self.material = material
    }

    /// False once `wipe()` has been called; sealing or opening with it then fails.
    public var isUsable: Bool { material != nil }

    /// Drops the key material. Call when an editing session ends, the device locks, or the
    /// PIN expires.
    public mutating func wipe() {
        material = nil
    }

    func withKey<T>(_ body: (SymmetricKey) throws -> T) throws -> T {
        guard let material else {
            throw FidoPassError.invalidState("The encryption key is no longer available — reopen the editor")
        }
        return try body(material)
    }
}
