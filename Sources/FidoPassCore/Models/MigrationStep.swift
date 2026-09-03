import Foundation

/// Stages of migrating a v1 portable account to v2, each of which may ask for a touch.
///
/// Four touches in all. Without naming them, the second prompt looks like the first one
/// failing and the app freezing after a successful touch.
public enum MigrationStep: Sendable, Hashable {
    /// Recovering the master key through the old credential. A touch.
    case readingOldAccount
    /// `makeCredential` for the copy. A touch.
    case creatingCredential
    /// The new credential's fixed component, for the mask. A touch.
    case derivingNewComponent
    /// Writing the record to the large-blob store. PIN only.
    case savingRecord
    /// Reading the copy back from the key and recovering the master key through it. A touch.
    case verifying
    /// Deleting the old credential. PIN only, and the last thing that happens.
    case deletingOld
    /// Something failed before the old account was deleted: the copy is being removed.
    case rollingBack
}
