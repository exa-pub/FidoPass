import Foundation

/// Password parameters not stored on the authenticator. Every account uses .v1; changing
/// these values changes derived passwords and requires an explicit versioned format.
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
