import Foundation

/// Whether the credential has the data required for derivation. Missing/corrupt v2
/// records and unreadable v1 portable masks must fail closed.
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
