import Foundation

public protocol PasswordGenerating: Sendable {
    func generatePassword(_ handle: AccountHandle,
                          label: String,
                          parameters: DerivationParameters,
                          pinProvider: (@Sendable () -> String?)?) throws -> String
}
