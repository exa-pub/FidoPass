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

    /// The message salt is the same in both formats: nothing about messages is frozen the
    /// way v1 passwords are, and a v1 account cannot be reached from a browser anyway.
    func deriveMessageSecret(_ handle: AccountHandle,
                             nonce: Data,
                             pinProvider: (@Sendable () -> String?)?) throws -> Data {
        try hmacSecretService.perform(handle,
                                      salt: SaltFactory.messageSalt(nonce: nonce),
                                      pinProvider: pinProvider)
    }
}
