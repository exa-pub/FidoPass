import Foundation

public protocol PasswordGenerating {
    func generatePassword(account: Account,
                          label: String,
                          policy override: PasswordPolicy?,
                          requireUV: Bool,
                          pinProvider: (() -> String?)?) throws -> String
}
