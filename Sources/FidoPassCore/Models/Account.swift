import Foundation

/// Account data read from a credential and its record. Connection state belongs to
/// AccountHandle; non-persisted password parameters belong to DerivationParameters.
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
    public var canDerive: Bool {
        integrity == .ok && Data(base64Encoded: credentialIdB64)?.isEmpty == false
            && (kind == .portable ? mask?.count == AccountRecord.maskByteCount : mask == nil)
            && (format != .v2 || identity != nil)
    }

    func validateForDerivation() throws {
        guard canDerive else {
            throw FidoPassError.invalidState(integrity.problem ?? "Account fields are inconsistent")
        }
    }

    /// Portable v1 accounts require migration for identity-based message links.
    /// Local v1 accounts cannot migrate and continue deriving from their original credential.
    public var needsMigration: Bool {
        format == .v1 && kind == .portable && integrity == .ok
    }
}
