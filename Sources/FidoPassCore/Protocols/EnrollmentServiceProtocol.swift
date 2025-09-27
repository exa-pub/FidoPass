import Foundation

public protocol EnrollmentServiceProtocol {
    func enroll(accountId: String,
                rpId: String,
                userName: String,
                requireUV: Bool,
                residentKey: Bool,
                devicePath: String?,
                askPIN: (() -> String?)?) throws -> Account

    func enumerateAccounts(rpId: String,
                           devicePath: String,
                           pin: String?) throws -> [Account]

    func deleteAccount(_ account: Account, pin: String?) throws

    func updateCredentialUserName(account: Account,
                                  newUserName: String,
                                  requireUV: Bool,
                                  pinProvider: (() -> String?)?) throws
}
