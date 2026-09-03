import Foundation

/// The salts, chosen by the account's format, and one `hmac-secret` assertion each.
final class SecretDerivationService: SecretDeriving, Sendable {
    private let hmacSecretService: HmacSecretService

    init(hmacSecretService: HmacSecretService) {
        self.hmacSecretService = hmacSecretService
    }

    func deriveSecret(_ handle: AccountHandle,
                      label: String,
                      revision: Int,
                      pinProvider: (@Sendable () -> String?)?) throws -> Data {
        let salt: Data
        switch handle.account.format {
        case .v1:
            salt = SaltFactory.residentSalt(label: label,
                                            rpId: handle.account.rpId,
                                            accountId: handle.account.id,
                                            revision: revision)
        case .v2:
            salt = SaltFactory.localPasswordSalt(label: label, revision: revision)
        }
        return try hmacSecretService.perform(handle, salt: salt, pinProvider: pinProvider)
    }

    func deriveFixedComponent(_ handle: AccountHandle,
                              pinProvider: (@Sendable () -> String?)?) throws -> Data {
        try hmacSecretService.perform(handle,
                                      salt: SaltFactory.fixedComponentSalt(format: handle.account.format),
                                      pinProvider: pinProvider)
    }

    func deriveMessageSecret(_ handle: AccountHandle,
                             nonce: Data,
                             pinProvider: (@Sendable () -> String?)?) throws -> Data {
        try hmacSecretService.perform(handle,
                                      salt: SaltFactory.messageKeySalt(nonce: nonce, format: handle.account.format),
                                      pinProvider: pinProvider)
    }
}
