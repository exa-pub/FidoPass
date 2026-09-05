import Foundation
import CryptoKit

/// RFC 9180 base mode: X25519/HKDF-SHA256/AES-128-GCM, implemented by CryptoKit.
/// Each message uses a fresh HPKE context. info binds the nonce and account locator; aad
/// is empty. Base mode does not authenticate the sender. See docs/crypto.md §6.
final class MessageSealer: MessageSealing, Sendable {
    static let domain = Data("fidopass|hpke|info|v1".utf8)

    /// Internal so the RFC 9180 vector test can drive CryptoKit with exactly this suite.
    static var ciphersuite: HPKE.Ciphersuite {
        HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_128)
    }

    init() {}

    func seal(_ plaintext: String, for key: EncryptionKeyURL) throws -> SealedMessageURL {
        guard plaintext.utf8.prefix(MessageLimits.maxPlaintextBytes + 1).count <= MessageLimits.maxPlaintextBytes else {
            throw FidoPassError.invalidState("Message exceeds the 1 MiB UTF-8 limit")
        }
        guard plaintext.count <= MessageLimits.maxPlaintextCharacters else {
            throw MessageCryptoError.tooLarge(limit: MessageLimits.maxPlaintextCharacters)
        }
        let recipient: Curve25519.KeyAgreement.PublicKey
        do {
            recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: key.publicKey)
        } catch {
            throw MessageCryptoError.invalidPublicKey
        }
        let info = Self.info(nonce: key.nonce, locator: key.locator)
        var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: Self.ciphersuite, info: info)
        let ciphertext = try sender.seal(Data(plaintext.utf8))
        return try SealedMessageURL(nonce: key.nonce,
                                    locator: key.locator,
                                    content: sender.encapsulatedKey + ciphertext)
    }

    func open(_ message: SealedMessageURL, with key: MessageKey) throws -> String {
        // The key was derived for one nonce; a message under another one cannot open with
        // it, and saying so here is clearer than an AEAD failure would be.
        guard message.nonce == key.url.nonce, message.locator == key.url.locator else {
            throw MessageCryptoError.authenticationFailed
        }
        let info = Self.info(nonce: message.nonce, locator: message.locator)
        let plaintext: Data = try key.withPrivateKey { privateKey in
            do {
                var recipient = try HPKE.Recipient(privateKey: privateKey,
                                                   ciphersuite: Self.ciphersuite,
                                                   info: info,
                                                   encapsulatedKey: message.encapsulatedKey)
                return try recipient.open(message.ciphertext)
            } catch {
                // CryptoKit does not distinguish a wrong key from altered data, and neither
                // can we.
                throw MessageCryptoError.authenticationFailed
            }
        }
        guard let text = String(data: plaintext, encoding: .utf8) else {
            throw MessageCryptoError.authenticationFailed
        }
        return text
    }

    func parseKey(_ text: String) throws -> EncryptionKeyURL {
        try EncryptionKeyURL(parsing: text)
    }

    func locator(nonce: Data, identity: AccountIdentity) throws -> AccountLocator {
        try AccountLocator.compute(nonce: nonce, identity: identity)
    }

    static func info(nonce: Data, locator: AccountLocator) -> Data {
        domain + nonce + locator.bytes
    }
}
