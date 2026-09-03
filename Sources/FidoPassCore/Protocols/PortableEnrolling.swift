import Foundation

public protocol PortableEnrolling: Sendable {
    /// Creates a portable account. Two touches, then a PIN-only write of the record.
    /// Returns the backup only when the key material was generated here — an import already
    /// has its own.
    func enrollPortable(accountId: String,
                        identity: AccountIdentity,
                        devicePath: String,
                        askPIN: (@Sendable () -> String?)?,
                        imported: PortableBackup?,
                        onStep: (@Sendable (PortableEnrollmentStep) -> Void)?) throws -> (AccountHandle, PortableBackup?)

    /// The account's master key and identity, recombined from the key. One touch. A v1
    /// account, which has no identity, exports what it always did: the master key alone.
    func exportBackup(_ handle: AccountHandle,
                      pinProvider: (@Sendable () -> String?)?) throws -> PortableBackup
}
