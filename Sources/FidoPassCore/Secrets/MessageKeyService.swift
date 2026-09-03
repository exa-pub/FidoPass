import Foundation
import CryptoKit

/// From an account and a nonce to an X25519 key pair — see `MessageKeyDeriving`.
///
/// ```
/// secret_local    = hmac-secret(cred, SHA256("fidopass|ecies|salt|v1" ‖ nonce))          // 32 raw bytes
/// secret_portable = HMAC-SHA256(key: fixed ⊕ external, SHA256("fidopass|ecies|portable|v1" ‖ nonce))
/// scalar          = clamp(argon2id("fidopass|ecies|x25519|v1" ‖ secret, salt: nonce, 32 bytes))
/// ```
///
/// `secret` is what the authenticator answered, byte for byte — never a password, never
/// anything `PasswordGenerator` produces. The two derivations share the credential and
/// nothing else: different salt domains, so a password and a message key cannot be computed
/// from one another. argon2id on the way to the scalar adds nothing to 256 bits of device
/// randomness except time, and the time is deliberate.
///
/// The account's identity goes into the locator only. It is not an input to the scalar,
/// which is what lets the same portable account on two keys issue the same public key.
final class MessageKeyService: MessageKeyDeriving, Sendable {
    static let scalarDomain = Data("fidopass|ecies|x25519|v1".utf8)

    private let secretDerivationService: SecretDeriving

    init(secretDerivationService: SecretDeriving) {
        self.secretDerivationService = secretDerivationService
    }

    func deriveMessageKey(_ handle: AccountHandle,
                          nonce: Data,
                          pinProvider: (@Sendable () -> String?)?) throws -> MessageKey {
        guard nonce.count == EncryptionKeyURL.nonceByteCount else {
            throw FidoPassError.invalidState("Nonce must be \(EncryptionKeyURL.nonceByteCount) bytes")
        }
        // The same gate as passwords: an account from before identities has no locator, so
        // no message could ever find it. Migrate first.
        guard let identity = handle.account.identity else { throw MessageCryptoError.accountNeedsMigration }

        let secret = try secret(for: handle, nonce: nonce, pinProvider: pinProvider)
        let scalar = try Argon2.id(password: Self.scalarDomain + secret,
                                   salt: nonce,
                                   parameters: .v1,
                                   outputByteCount: 32)
        let url = try EncryptionKeyURL(nonce: nonce,
                                       publicKey: try MessageKey.publicKey(for: scalar),
                                       locator: try AccountLocator.compute(nonce: nonce, identity: identity))
        return MessageKey(url: url, scalar: scalar)
    }

    /// One touch either way.
    private func secret(for handle: AccountHandle,
                        nonce: Data,
                        pinProvider: (@Sendable () -> String?)?) throws -> Data {
        switch handle.account.kind {
        case .local:
            let answer = try secretDerivationService.deriveMessageSecret(handle, nonce: nonce, pinProvider: pinProvider)
            guard answer.count == 32 else {
                throw FidoPassError.invalidState("hmac-secret must answer with 32 bytes")
            }
            return answer
        case .portable:
            let masterKey = try PortableMasterKey.recover(handle, using: secretDerivationService, pinProvider: pinProvider)
            let mac = HMAC<SHA256>.authenticationCode(for: SaltFactory.portableMessageSalt(nonce: nonce),
                                                      using: SymmetricKey(data: masterKey))
            return Data(mac)
        }
    }
}
