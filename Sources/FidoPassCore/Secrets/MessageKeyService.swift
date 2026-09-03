import Foundation
import CryptoKit

/// From an account and a nonce to an X25519 key pair — see `MessageKeyDeriving`.
///
/// ```
/// secret_local    = hmac-secret(cred, SaltFactory.messageSalt(nonce))                 // 32 raw bytes
/// secret_portable = HMAC-SHA256(key: fixed ⊕ mask, SaltFactory.messageSalt(nonce))
/// ikm             = argon2id("fidopass|hpke|ikm|v1" ‖ secret, salt: nonce, 32 bytes)
/// (sk, pk)        = DHKEM(X25519, HKDF-SHA256).DeriveKeyPair(ikm)                      // RFC 9180 §7.1.3
/// ```
///
/// `secret` is what the authenticator answered, byte for byte — never a password, never
/// anything `PasswordGenerator` produces. The two derivations share the credential and
/// nothing else: different salt domains, so a password and a message key cannot be computed
/// from one another. argon2id on the way to `ikm` adds nothing to 256 bits of device
/// randomness except time, and the time is deliberate; from `ikm` on, the key pair is the
/// HPKE standard's own derivation, which is what lets any other implementation arrive at the
/// same public key.
///
/// The account's identity goes into the locator only. It is not an input to the key pair,
/// which is what lets the same portable account on two keys issue the same public key.
final class MessageKeyService: MessageKeyDeriving, Sendable {
    static let ikmDomain = Data("fidopass|hpke|ikm|v1".utf8)

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
        if let problem = handle.account.integrity.problem {
            throw FidoPassError.invalidState(problem)
        }
        // A portable v1 account has no identity, so no locator, so no message could ever
        // find it. Migrate first.
        guard let identity = handle.account.identity else { throw MessageCryptoError.accountNeedsMigration }

        let secret = try secret(for: handle, nonce: nonce, pinProvider: pinProvider)
        let ikm = try Argon2.id(password: Self.ikmDomain + secret,
                                salt: nonce,
                                parameters: .v1,
                                outputByteCount: DHKEM.inputKeyMaterialByteCount)
        let pair = try DHKEM.deriveKeyPair(ikm: ikm)
        let url = try EncryptionKeyURL(nonce: nonce,
                                       publicKey: pair.publicKey,
                                       locator: try AccountLocator.compute(nonce: nonce, identity: identity))
        return MessageKey(url: url, privateKey: pair.privateKey)
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
            let mac = HMAC<SHA256>.authenticationCode(for: SaltFactory.messageSalt(nonce: nonce),
                                                      using: SymmetricKey(data: masterKey))
            return Data(mac)
        }
    }
}
