import Foundation
import CryptoKit

/// Derives a message key from raw authenticator output (local) or HMAC under the portable
/// master key, followed by Argon2id and RFC 9180 DeriveKeyPair. Never uses a password.
/// The account identity affects only the locator. Frozen byte definitions: docs/crypto.md §6.
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
        try handle.account.validateForDerivation()
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
