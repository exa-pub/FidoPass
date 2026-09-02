import Foundation

public struct Account: Codable, Hashable, Identifiable, Sendable {
    /// User-chosen identifier, unique per authenticator. Feeds salt derivation.
    public var id: String
    public var kind: AccountKind
    /// Human-readable name shown in the UI. Not part of derivation.
    public var displayName: String
    public var credentialIdB64: String
    public var revision: Int
    public var policy: PasswordPolicy
    /// Session handle of the authenticator this account was read from.
    ///
    /// Device paths change on every reconnect, so this is never a stable identity — it is
    /// only valid for as long as the device stays plugged in.
    public var devicePath: String?
    /// Present exactly when `kind == .portable`.
    public var portable: PortablePayload?

    public var rpId: String { kind.rpId }

    public init(id: String,
                kind: AccountKind,
                displayName: String = "",
                credentialIdB64: String,
                revision: Int = 1,
                policy: PasswordPolicy = PasswordPolicy(),
                devicePath: String?,
                portable: PortablePayload? = nil) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.credentialIdB64 = credentialIdB64
        self.revision = revision
        self.policy = policy
        self.devicePath = devicePath
        self.portable = portable
    }

    /// Identity is the pair (account id, device), not the id alone.
    ///
    /// The same account id legitimately exists on several authenticators — that is exactly
    /// what a portable backup key looks like. Comparing ids alone made those entries
    /// indistinguishable to `List(selection:)`, so selecting one selected both.
    public static func == (lhs: Account, rhs: Account) -> Bool {
        lhs.id == rhs.id && lhs.devicePath == rhs.devicePath
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(devicePath)
    }
}
