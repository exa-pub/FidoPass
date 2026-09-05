import Foundation

/// Secret portable master key and optional account identity. Legacy backups without an
/// identity remain readable. Intentionally not Codable or printable through a description.
public struct PortableBackup: Hashable, Sendable {
    public static let masterKeyByteCount = 32

    public let masterKey: Data
    public let identity: AccountIdentity?

    public init?(masterKey: Data, identity: AccountIdentity?) {
        guard masterKey.count == Self.masterKeyByteCount else { return nil }
        self.masterKey = Data(masterKey)
        self.identity = identity
    }

    /// Parses the text a person pastes: 64 characters for a backup with an identity, 44 for
    /// one from a version that predates them. Whitespace is ignored — the value is printed,
    /// typed and wrapped by whatever it was stored in.
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

    /// 64 characters with an identity, 44 without.
    public var base64: String {
        var bytes = masterKey
        if let identity { bytes.append(identity.bytes) }
        return bytes.base64EncodedString()
    }

    /// Made by a version that predates identities: the master key alone.
    public var isLegacy: Bool { identity == nil }

    /// The same master key with an identity chosen for it — what importing a legacy backup
    /// does once the user has picked or accepted one, and what happens when someone types
    /// over the identity a current backup carries.
    public func withIdentity(_ identity: AccountIdentity) -> PortableBackup {
        PortableBackup(masterKey: masterKey, identity: identity)!
    }
}
