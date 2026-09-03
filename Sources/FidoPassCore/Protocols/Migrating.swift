import Foundation

/// Moves a portable v1 account to the v2 layout by recreating it — see
/// `AccountMigrationService` for the order of operations and what each failure leaves.
public protocol Migrating: Sendable {
    /// Creates the v2 copy, verifies it through the production read path and only then
    /// deletes the original. Four touches.
    func migrate(_ old: AccountHandle,
                 identity: AccountIdentity,
                 askPIN: (@Sendable () -> String?)?,
                 onStep: (@Sendable (MigrationStep) -> Void)?) throws -> AccountHandle

    /// Converges an interrupted migration from whatever state the copy is in: a copy
    /// without a record is discarded and the migration run again with its identity; a copy
    /// with one is verified and the original deleted.
    func finishMigration(old: AccountHandle,
                         copy: AccountHandle,
                         askPIN: (@Sendable () -> String?)?,
                         onStep: (@Sendable (MigrationStep) -> Void)?) throws -> AccountHandle

    /// Deletes an unfinished copy and its record. The original is untouched. PIN, no touch.
    func discardMigrationCopy(_ copy: AccountHandle, pin: String?) throws
}
