import Foundation

public protocol PortableEnrollmentServiceProtocol {
    func enrollPortable(accountId: String,
                        requireUV: Bool,
                        devicePath: String?,
                        askPIN: (() -> String?)?,
                        importedKeyB64: String?) throws -> (Account, String?)

    func exportImportedKey(_ account: Account,
                           requireUV: Bool,
                           pinProvider: (() -> String?)?) throws -> String
}
