import Foundation

/// What the key holds for one FidoPass account — and nothing that it does not.
///
/// Identity is the credential id: it names one credential on one key, does not change on a
/// reconnect, and differs between a portable account and its copy on a second key. Where
/// the account was read from is session state and lives in `AccountHandle`; what the
/// derivation is parameterised by is `DerivationParameters`, because the authenticator
/// stores no metadata for it.
public struct Account: Codable, Hashable, Identifiable, Sendable {
    /// User-chosen identifier, unique per authenticator. Feeds salt derivation.
    public var id: String
    public var kind: AccountKind
    public var credentialIdB64: String
    /// Present exactly when `kind == .portable`.
    public var portable: PortablePayload?

    public var rpId: String { kind.rpId }

    public init(id: String,
                kind: AccountKind,
                credentialIdB64: String,
                portable: PortablePayload? = nil) {
        self.id = id
        self.kind = kind
        self.credentialIdB64 = credentialIdB64
        self.portable = portable
    }

    /// Twelve bytes that tell this account apart from another one with the same id — see
    /// `AccountIdentity`. Derived for a local account, stored for a portable one, and `nil`
    /// only for a portable account written before identities existed.
    public var identity: AccountIdentity? {
        switch kind {
        case .local:
            return Data(base64Encoded: credentialIdB64).map(AccountIdentity.derived(fromCredentialId:))
        case .portable:
            return portable?.identity
        }
    }

    /// A portable account written by an earlier version: key material without an identity.
    ///
    /// It derives the same passwords it always did — the identity is not an input — so the
    /// core keeps deriving for it. What it cannot do is show a fingerprint or export a
    /// backup that carries one, until `assignIdentity` writes one to the key.
    public var needsMigration: Bool {
        kind == .portable && portable?.needsMigration == true
    }
}
