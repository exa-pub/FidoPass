import Foundation

public protocol Enrolling: Sendable {
    func enroll(accountId: String,
                kind: AccountKind,
                devicePath: String,
                askPIN: (@Sendable () -> String?)?) throws -> AccountHandle

    func enumerateAccounts(rpId: String,
                           devicePath: String,
                           pin: String?) throws -> [AccountHandle]

    func deleteAccount(_ handle: AccountHandle, pin: String?) throws

    func updateCredentialUserInfo(_ handle: AccountHandle,
                                  pinProvider: (@Sendable () -> String?)?) throws
}
