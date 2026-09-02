import Foundation

public protocol PasswordGenerating: Sendable {
    func generatePassword(account: Account,
                          label: String,
                          policy override: PasswordPolicy?,
                          requireUV: Bool,
                          pinProvider: (@Sendable () -> String?)?) throws -> String
}
