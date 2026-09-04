import Foundation
import CryptoKit

/// Account key for one nonce. The private half stays in Core.
/// A receiving window caches it per credential and nonce until close. wipe() releases
/// this value’s reference; it cannot erase other Swift or CryptoKit copies.
public struct MessageKey: Sendable {
    /// Everything public: nonce, public key, locator, fingerprint.
    public let url: EncryptionKeyURL
    /// The raw X25519 scalar `DHKEM.deriveKeyPair` returned, 32 bytes; nil once wiped.
    private var privateKey: Data?

    init(url: EncryptionKeyURL, privateKey: Data) {
        precondition(privateKey.count == DHKEM.privateKeyByteCount, "an X25519 private key is 32 bytes")
        self.url = url
        self.privateKey = Data(privateKey)
    }

    /// False once `wipe()` has been called; opening with it then fails.
    public var isUsable: Bool { privateKey != nil }

    /// Drops the private material. Call when the window closes, the key locks, or the
    /// session locks.
    public mutating func wipe() {
        privateKey = nil
    }

    func withPrivateKey<T>(_ body: (Curve25519.KeyAgreement.PrivateKey) throws -> T) throws -> T {
        guard let privateKey else {
            throw FidoPassError.invalidState("The key is no longer available — reopen the window")
        }
        return try body(try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey))
    }

    /// The public key for a raw private key — what goes into the link. X25519 clamps the
    /// scalar itself, so no clamping happens here (`DHKEM`).
    static func publicKey(for privateKey: Data) throws -> Data {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey).publicKey.rawRepresentation
    }
}
