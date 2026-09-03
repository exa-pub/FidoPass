import Foundation

/// How much user verification a credential demands, as CTAP's `credProtect` extension.
public enum CredentialProtection: Int, Sendable, Hashable, Codable, CaseIterable {
    /// The authenticator's default when nothing was requested.
    case uvOptional = 1
    case uvOptionalWithCredentialID = 2
    case uvRequired = 3

    public var summary: String {
        switch self {
        case .uvOptional: return "1 — user verification optional"
        case .uvOptionalWithCredentialID: return "2 — optional with credential id"
        case .uvRequired: return "3 — user verification required"
        }
    }
}
