import Foundation

public protocol SecretDerivationServiceProtocol {
    func deriveSecret(account: Account,
                      label: String,
                      requireUV: Bool,
                      pinProvider: (() -> String?)?) throws -> Data

    func deriveFixedComponent(account: Account,
                              requireUV: Bool,
                              pinProvider: (() -> String?)?) throws -> Data
}
