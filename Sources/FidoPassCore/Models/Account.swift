import Foundation

/// What the key holds for one FidoPass account — and nothing that it does not.
///
/// Where the account was read from is session state and lives in `AccountHandle`; what the
/// derivation is parameterised by is `DerivationParameters`, because the authenticator
/// stores no metadata for it. Which layout it is in is `format`, and the fields say where
/// each value came from: for v2, the identity is `user.id` and the mask comes from the
/// account's record; for v1, the identity is derived (local) or absent (portable) and the
/// mask is what `user.name` held.
public struct Account: Codable, Hashable, Identifiable, Sendable {
    /// The account's name: `user.name` for v2, `user.id` as UTF-8 for v1. Unique per key.
    /// Feeds salt derivation for v1 local accounts only.
    public var id: String
    public var kind: AccountKind
    public var format: AccountFormat
    public var credentialIdB64: String
    /// Sixteen bytes that tell this account apart from another one with the same id — see
    /// `AccountIdentity`. Stored for v2, derived for v1 local, and `nil` only for a portable
    /// v1 account, which has none until it is migrated.
    public var identity: AccountIdentity?
    /// A portable account's masked master key, 32 bytes: the master key XOR-ed with a
    /// component only this credential derives, so it is useless without the key it lives on.
    /// `nil` for a local account.
    public var mask: Data?
    public var integrity: AccountIntegrity

    public var rpId: String { format.rpId(for: kind) }

    public init(id: String,
                kind: AccountKind,
                format: AccountFormat,
                credentialIdB64: String,
                identity: AccountIdentity?,
                mask: Data? = nil,
                integrity: AccountIntegrity = .ok) {
        self.id = id
        self.kind = kind
        self.format = format
        self.credentialIdB64 = credentialIdB64
        self.identity = identity
        self.mask = mask.map { Data($0) }
        self.integrity = integrity
    }

    /// Whether anything may be derived from this account. A credential without a usable
    /// record is not an account; nothing reads it, and the only action offered is deletion.
    public var canDerive: Bool { integrity == .ok }

    /// A portable account in the v1 layout: key material in `user.name`, no identity, not
    /// reachable from a browser. It derives what it always did — migration reproduces the
    /// same master key under a v2 credential and then deletes this one.
    ///
    /// A local v1 account is not in this set: its material cannot be moved to a new
    /// credential, so it stays as it is, for good.
    public var needsMigration: Bool {
        format == .v1 && kind == .portable && integrity == .ok
    }
}
