import Foundation

public protocol PortableEnrolling: Sendable {
    func enrollPortable(accountId: String,
                        requireUV: Bool,
                        devicePath: String,
                        askPIN: (@Sendable () -> String?)?,
                        importedKeyB64: String?,
                        onStep: (@Sendable (PortableEnrollmentStep) -> Void)?) throws -> (Account, String?)

    func exportImportedKey(_ account: Account,
                           requireUV: Bool,
                           pinProvider: (@Sendable () -> String?)?) throws -> String
}
