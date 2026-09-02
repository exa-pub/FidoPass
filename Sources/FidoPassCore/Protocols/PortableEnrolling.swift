import Foundation

public protocol PortableEnrolling: Sendable {
    /// Creates a portable account. Two touches. Returns the backup only when the key
    /// material was generated here — an import already has its own.
    func enrollPortable(accountId: String,
                        devicePath: String,
                        askPIN: (@Sendable () -> String?)?,
                        imported: PortableBackup?,
                        onStep: (@Sendable (PortableEnrollmentStep) -> Void)?) throws -> (AccountHandle, PortableBackup?)

    /// The account's master key and identity, recombined from the key. One touch. An
    /// account written before identities existed exports what it always did: the master
    /// key alone.
    func exportBackup(_ handle: AccountHandle,
                      pinProvider: (@Sendable () -> String?)?) throws -> PortableBackup

    /// Writes an identity onto a portable account that has none. PIN, no touch; the key
    /// material — and so every password — is untouched. Refused for an account that already
    /// has one.
    func assignIdentity(_ handle: AccountHandle,
                        identity: AccountIdentity,
                        pinProvider: (@Sendable () -> String?)?) throws -> AccountHandle
}
