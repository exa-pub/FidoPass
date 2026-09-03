import Foundation

/// How an account is laid out on the key. Two layouts exist; only the second is written.
///
/// **v1** — the released format. The account's name is its `user.id`; a portable account
/// keeps its masked master key in `user.name`; the kind is the relying party
/// (`fidopass.local`, `fidopass.portable`), which also enters a local account's salt.
///
/// **v2** — one relying party for both kinds. `user.id` is the identity, `user.name` and
/// `user.displayName` are the name and nothing else, and what the account *is* — its kind,
/// and for a portable account its mask — lives in a record in the key's large-blob store
/// (`AccountRecord`). Laid out so that a browser, which sees a credential only through
/// WebAuthn, can read everything it needs from one assertion.
///
/// The relying-party ids are frozen. They enter every credential, and the v1 ones enter the
/// salt of every v1 local password; the v2 one is the domain a web page has to be served
/// from to reach these credentials, and a credential cannot be moved to another.
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
