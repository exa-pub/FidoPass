import Foundation

/// Stages of a portable enrolment, each of which may ask the user to touch the key.
///
/// Creating the credential and deriving the backup key are two separate authenticator
/// operations, so the user is prompted twice. Without this, the second prompt looks like
/// the app freezing after a successful touch.
public enum PortableEnrollmentStep: Sendable {
    case creatingCredential
    case derivingBackupKey
    case savingPayload
}

public protocol PortableEnrollmentServiceProtocol {
    func enrollPortable(accountId: String,
                        requireUV: Bool,
                        devicePath: String?,
                        askPIN: (() -> String?)?,
                        importedKeyB64: String?,
                        onStep: ((PortableEnrollmentStep) -> Void)?) throws -> (Account, String?)

    func exportImportedKey(_ account: Account,
                           requireUV: Bool,
                           pinProvider: (() -> String?)?) throws -> String
}
