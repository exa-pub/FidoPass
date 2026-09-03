import Foundation

/// Stages of a portable enrolment, each of which may ask the user to touch the key.
///
/// Creating the credential and deriving the backup key are two separate authenticator
/// operations, so the user is prompted twice. Without this, the second prompt looks like
/// the app freezing after a successful touch.
public enum PortableEnrollmentStep: Sendable {
    case creatingCredential
    case derivingBackupKey
    /// Writing the account's record — kind and mask — to the key's large-blob store. PIN only.
    case savingRecord
}
