import Foundation

final class SecretDerivationService: SecretDeriving, Sendable {
    private let hmacSecretService: HmacSecretService

    init(hmacSecretService: HmacSecretService) {
        self.hmacSecretService = hmacSecretService
    }

    func deriveSecret(_ handle: AccountHandle,
                      label: String,
                      revision: Int,
                      pinProvider: (@Sendable () -> String?)?) throws -> Data {
        let salt = SaltFactory.residentSalt(label: label,
                                            rpId: handle.account.rpId,
                                            accountId: handle.account.id,
                                            revision: revision)
        return try hmacSecretService.perform(handle, salt: salt, pinProvider: pinProvider)
    }

    func deriveFixedComponent(_ handle: AccountHandle,
                              pinProvider: (@Sendable () -> String?)?) throws -> Data {
        try hmacSecretService.perform(handle, salt: SaltFactory.fixedComponentSalt(), pinProvider: pinProvider)
    }
}
