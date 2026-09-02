import Foundation

public protocol SecretDerivationServiceProtocol: Sendable {
    func deriveSecret(account: Account,
                      label: String,
                      requireUV: Bool,
                      pinProvider: (@Sendable () -> String?)?) throws -> Data

    func deriveFixedComponent(account: Account,
                              requireUV: Bool,
                              pinProvider: (@Sendable () -> String?)?) throws -> Data
}
