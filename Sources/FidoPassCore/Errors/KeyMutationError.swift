import Foundation

/// A write completed before a later step failed. The caller must refresh, never claim that
/// the entire operation was rolled back. Carries no key material or persisted journal.
public struct KeyMutationError: Error, LocalizedError {
    public enum Completed: Sendable {
        case credentialCreated
        case credentialDeleted
        case migrationCopyVerified
    }
    public let completed: Completed
    public let underlying: any Error

    public init(completed: Completed, underlying: any Error) {
        self.completed = completed
        self.underlying = underlying
    }

    public var errorDescription: String? {
        switch completed {
        case .credentialCreated:
            "A credential may remain on the key. Refresh its accounts before trying again."
        case .credentialDeleted:
            "The credential was deleted, but its encrypted record could not be removed. Refresh the key's accounts."
        case .migrationCopyVerified:
            "The new copy was verified, but deleting the original did not complete. Refresh accounts to finish the migration."
        }
    }
}
