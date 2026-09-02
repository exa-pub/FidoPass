import Foundation

/// The inputs to derivation that are not on the key.
///
/// `revision` enters the salt and `policy` shapes the output and its HKDF info, so both are
/// part of the compatibility contract: change either and every password already in use
/// changes with it. The authenticator stores no metadata for them, which is why every
/// account derives with `.v1` today; when a key-side store for them exists, this is the
/// value it will be loaded into — per account, and never silently.
public struct DerivationParameters: Hashable, Sendable {
    public let revision: Int
    public let policy: PasswordPolicy

    public init(revision: Int, policy: PasswordPolicy) {
        self.revision = revision
        self.policy = policy
    }

    /// What every account derives with until parameters can be stored per account.
    public static let v1 = DerivationParameters(revision: 1, policy: PasswordPolicy())
}
