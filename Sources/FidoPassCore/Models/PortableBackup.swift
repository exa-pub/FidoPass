import Foundation

/// What leaves the key when a portable account is backed up, and what comes back on import.
///
/// The master key is the secret: with it, every password of the account can be derived
/// without any security key. The identity travels with it so that the account this is
/// imported into shows the same fingerprint as the one it was exported from. A backup made
/// by a version that predates identities has none (`isLegacy`) and is still accepted —
/// people keep these on paper for years, and refusing one would strand exactly the person
/// the portable kind exists for.
///
/// Deliberately not `Codable` and without a description: this value must not be able to
/// reach a JSON export or a log by accident. It is shown on one screen and copied by one
/// button, both of which know what they are handling.
public struct PortableBackup: Hashable, Sendable {
    public static let masterKeyByteCount = 32

    public let masterKey: Data
    public let identity: AccountIdentity?

    public init?(masterKey: Data, identity: AccountIdentity?) {
        guard masterKey.count == Self.masterKeyByteCount else { return nil }
        self.masterKey = Data(masterKey)
        self.identity = identity
    }

    /// Parses the text a person pastes: 60 characters for a backup with an identity, 44 for
    /// one from an earlier version. Whitespace is ignored — the value is printed, typed and
    /// wrapped by whatever it was stored in.
    public init?(base64: String) {
        let compact = base64.filter { !$0.isWhitespace }
        guard let decoded = Data(base64Encoded: compact) else { return nil }
        switch decoded.count {
        case Self.masterKeyByteCount:
            self.init(masterKey: decoded, identity: nil)
        case Self.masterKeyByteCount + AccountIdentity.byteCount:
            guard let identity = AccountIdentity(bytes: decoded.suffix(AccountIdentity.byteCount)) else { return nil }
            self.init(masterKey: decoded.prefix(Self.masterKeyByteCount), identity: identity)
        default:
            return nil
        }
    }

    /// 60 characters with an identity, 44 without.
    public var base64: String {
        var bytes = masterKey
        if let identity { bytes.append(identity.bytes) }
        return bytes.base64EncodedString()
    }

    /// Made by a version that predates identities: the master key alone.
    public var isLegacy: Bool { identity == nil }

    /// The same master key with an identity chosen for it — what importing a legacy backup
    /// does once the user has picked or accepted one.
    public func withIdentity(_ identity: AccountIdentity) -> PortableBackup {
        PortableBackup(masterKey: masterKey, identity: identity)!
    }
}
