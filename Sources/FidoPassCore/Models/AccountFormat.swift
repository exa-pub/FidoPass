import Foundation

/// Read-only v1 uses separate relying parties and stores portable masks in user.name.
/// V2 uses one relying party, user.id for identity and AccountRecord for kind/mask.
/// Relying-party IDs and layouts are immutable; see docs/crypto.md §4.
public enum AccountFormat: String, Codable, Hashable, CaseIterable, Sendable {
    case v1
    case v2

    /// The relying party every v2 account is created under. A domain, because WebAuthn lets
    /// a page use a credential only when the page's origin is under its relying party.
    public static let v2RelyingPartyId = "fidopass.org"

    public func rpId(for kind: AccountKind) -> String {
        switch self {
        case .v1: return kind.rpId
        case .v2: return Self.v2RelyingPartyId
        }
    }

    /// Every relying party FidoPass has ever written under, in the order they are read.
    public static var relyingPartyIds: [String] {
        AccountKind.allCases.map(\.rpId) + [v2RelyingPartyId]
    }

    /// What a relying party says about a credential: which format, and — for v1, where the
    /// kind is the relying party — which kind. For v2 the kind is in the record.
    public static func parse(rpId: String) -> (format: AccountFormat, kind: AccountKind?)? {
        if rpId == v2RelyingPartyId { return (.v2, nil) }
        if let kind = AccountKind(rpId: rpId) { return (.v1, kind) }
        return nil
    }
}
