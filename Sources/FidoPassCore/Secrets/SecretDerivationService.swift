import Foundation

final class SecretDerivationService: SecretDerivationServiceProtocol {
    private let hmacSecretService: HmacSecretService

    init(hmacSecretService: HmacSecretService) {
        self.hmacSecretService = hmacSecretService
    }

    func deriveSecret(account: Account,
                      label: String,
                      requireUV: Bool,
                      pinProvider: (() -> String?)?) throws -> Data {
        let salt = SaltFactory.residentSalt(label: label,
                                            rpId: account.rpId,
                                            accountId: account.id,
                                            revision: account.revision)
        return try hmacSecretService.perform(account: account,
                                             salt: salt,
                                             requireUV: requireUV,
                                             pinProvider: pinProvider)
    }

    func deriveFixedComponent(account: Account,
                              requireUV: Bool,
                              pinProvider: (() -> String?)?) throws -> Data {
        let salt = SaltFactory.fixedComponentSalt()
        return try hmacSecretService.perform(account: account,
                                             salt: salt,
                                             requireUV: requireUV,
                                             pinProvider: pinProvider)
    }
}
