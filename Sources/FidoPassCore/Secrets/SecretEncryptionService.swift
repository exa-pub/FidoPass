import Foundation
import CryptoKit

final class SecretEncryptionService: SecretEncrypting {
    private let secretDerivationService: SecretDerivationServiceProtocol

    init(secretDerivationService: SecretDerivationServiceProtocol) {
        self.secretDerivationService = secretDerivationService
    }

    func deriveEncryptionKey(account: Account,
                             label: String,
                             requireUV: Bool,
                             pinProvider: (() -> String?)?) throws -> EncryptionKey {
        let secret = try secretDerivationService.deriveSecret(account: account,
                                                              label: label,
                                                              requireUV: requireUV,
                                                              pinProvider: pinProvider)
        return EncryptionKey(material: Self.deriveKeyMaterial(from: secret))
    }

    /// Separates the encryption key from the password material derived from the same secret.
    ///
    /// The password is routinely pasted into other applications. If the encryption key could
    /// be computed from it, disclosing a password would disclose every value ever encrypted
    /// under that account and label. Different salt and info make the two outputs
    /// independent: knowing one says nothing about the other.
    static func deriveKeyMaterial(from secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                               salt: Data("aes-key".utf8),
                               info: Data("fidopass|aes|v1".utf8),
                               outputByteCount: 32)
    }

    func seal(_ plaintext: String, with key: EncryptionKey) throws -> String {
        try seal(plaintext, with: key, nonce: nil)
    }

    /// - Parameter nonce: supplied only by tests, which cannot pin an output that changes
    ///   every call. Production always generates a fresh random nonce.
    func seal(_ plaintext: String, with key: EncryptionKey, nonce: AES.GCM.Nonce?) throws -> String {
        guard plaintext.count <= SecretCrypto.maxPlaintextCharacters else {
            throw SecretCryptoError.tooLarge(limit: SecretCrypto.maxPlaintextCharacters)
        }
        return try key.withKey { material in
            let box = try AES.GCM.seal(Data(plaintext.utf8),
                                       using: material,
                                       nonce: nonce ?? AES.GCM.Nonce())
            guard let combined = box.combined else {
                throw FidoPassError.invalidState("AES-GCM produced no combined representation")
            }
            return CryptoEnvelope.encode(sealed: combined).base64EncodedString()
        }
    }

    func open(_ envelopeB64: String, with key: EncryptionKey) throws -> String {
        let trimmed = envelopeB64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Ignore whitespace so a value wrapped across lines by another app still opens.
        guard let raw = Data(base64Encoded: trimmed, options: [.ignoreUnknownCharacters]) else {
            throw SecretCryptoError.notBase64
        }
        let sealed = try CryptoEnvelope.decode(raw)

        return try key.withKey { material in
            let box: AES.GCM.SealedBox
            do {
                box = try AES.GCM.SealedBox(combined: sealed)
            } catch {
                throw SecretCryptoError.notFidoPassEnvelope
            }
            let plaintext: Data
            do {
                plaintext = try AES.GCM.open(box, using: material)
            } catch {
                // CryptoKit does not distinguish a wrong key from altered data, and neither
                // can we: the envelope carries nothing that identifies the key.
                throw SecretCryptoError.authenticationFailed
            }
            guard let text = String(data: plaintext, encoding: .utf8) else {
                throw SecretCryptoError.authenticationFailed
            }
            return text
        }
    }
}
