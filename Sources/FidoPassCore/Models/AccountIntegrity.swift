import Foundation

/// Whether an account as read from the key is whole enough to derive from.
///
/// A v2 credential without its record — an enrolment that was interrupted between the touch
/// and the write, a blob store rewritten by another tool — is a credential and not an
/// account: nothing is derived from it, and the one thing to do with it is delete it. The
/// v1 equivalent is a portable credential whose `user.name` does not hold its key material.
public enum AccountIntegrity: String, Codable, Hashable, Sendable {
    case ok
    /// A v2 credential with no record in the large-blob store.
    case recordMissing
    /// A record that does not parse — or, for v1, key material that does not.
    case recordCorrupt

    /// What is wrong, for a person. `nil` when nothing is.
    public var problem: String? {
        switch self {
        case .ok:
            return nil
        case .recordMissing:
            return "This account has no record on the key — its creation did not finish. Delete it and create it again."
        case .recordCorrupt:
            return "This account's record on the key cannot be read. Delete it and create it again."
        }
    }
}
