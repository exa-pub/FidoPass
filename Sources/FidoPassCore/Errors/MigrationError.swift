import Foundation

/// Why a migration did not go through — and, when it matters, what it left behind.
public enum MigrationError: Error, Equatable, LocalizedError, Sendable {
    /// Only a portable v1 account migrates: a local one cannot move its material, a v2 one
    /// is already there, and one without readable material has nothing to move.
    case notMigratable(String)
    /// A v2 account with this name already exists on the key — an earlier attempt got as far
    /// as creating the copy. Finish or discard that one rather than making another.
    case copyExists(name: String)
    /// The copy, read back from the key, does not derive the same master key as the original.
    /// The original is untouched; the copy has been removed.
    case verificationFailed
    /// Something failed after the copy was created, and removing it failed too — the key was
    /// unplugged, most likely. The original is untouched; the copy is still on the key.
    case copyRemains(name: String, reason: String)
    /// The copy this was asked to finish is no longer on the key.
    case copyNotFound

    public var errorDescription: String? {
        switch self {
        case .notMigratable(let reason):
            return reason
        case .copyExists(let name):
            return "An unfinished copy of “\(name)” is already on this key — finish or discard it first"
        case .verificationFailed:
            return "The copy did not reproduce the same master key. Nothing was changed; the copy was removed."
        case .copyRemains(let name, let reason):
            return "Migration stopped (\(reason)), and the unfinished copy of “\(name)” could not be removed. Reconnect the key, then finish or discard it."
        case .copyNotFound:
            return "The unfinished copy is no longer on the key"
        }
    }
}
