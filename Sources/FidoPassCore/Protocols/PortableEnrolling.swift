import Foundation

public protocol PortableEnrolling: Sendable {
    func enrollPortable(accountId: String,
                        devicePath: String,
                        askPIN: (@Sendable () -> String?)?,
                        importedKeyB64: String?,
                        onStep: (@Sendable (PortableEnrollmentStep) -> Void)?) throws -> (AccountHandle, String?)

    func exportImportedKey(_ handle: AccountHandle,
                           pinProvider: (@Sendable () -> String?)?) throws -> String
}
