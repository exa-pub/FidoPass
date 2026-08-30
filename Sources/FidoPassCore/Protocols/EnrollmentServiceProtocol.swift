import Foundation

public protocol EnrollmentServiceProtocol {
    func enroll(accountId: String,
                kind: AccountKind,
                displayName: String,
                requireUV: Bool,
                devicePath: String?,
                askPIN: (() -> String?)?) throws -> Account

    func enumerateAccounts(rpId: String,
                           devicePath: String,
                           pin: String?) throws -> [Account]

    func deleteAccount(_ account: Account, pin: String?) throws

    func updateCredentialUserInfo(account: Account,
                                  requireUV: Bool,
                                  pinProvider: (() -> String?)?) throws
}
