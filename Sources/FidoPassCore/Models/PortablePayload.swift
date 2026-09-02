import Foundation

/// What a portable account carries on the authenticator, in the credential's `user.name`.
///
/// `external` is the imported master key XOR-ed with a component derived from this
/// authenticator, so it is useless without the key that produced it. Recombining the two
/// yields the master key, which is what lets a second authenticator reproduce the same
/// passwords.
///
/// `identity` sits after it — twelve bytes that name the account without being part of any
/// derivation (`AccountIdentity`). It is absent on a payload written by a version that
/// predates identities; such an account still derives exactly what it always did, and
/// `PortableEnrollmentService.assignIdentity` gives it one in place.
///
/// Two layouts, told apart by length: 32 bytes (v1) and 32 + 12 bytes (v2). Nothing else is
/// a payload. v2 is 60 characters of base64, under the 64 bytes CTAP lets an authenticator
/// keep for `user.name`, and `CredentialUserFieldsTests` pins that margin.
public struct PortablePayload: Hashable, Codable, Sendable {
    public static let externalByteCount = 32

    public let external: Data
    public let identity: AccountIdentity?

    public init?(external: Data, identity: AccountIdentity? = nil) {
        guard external.count == Self.externalByteCount else { return nil }
        self.external = Data(external)
        self.identity = identity
    }

    public init?(base64: String) {
        guard let decoded = Data(base64Encoded: base64) else { return nil }
        switch decoded.count {
        case Self.externalByteCount:
            self.init(external: decoded, identity: nil)
        case Self.externalByteCount + AccountIdentity.byteCount:
            guard let identity = AccountIdentity(bytes: decoded.suffix(AccountIdentity.byteCount)) else { return nil }
            self.init(external: decoded.prefix(Self.externalByteCount), identity: identity)
        default:
            return nil
        }
    }

    /// The layout that is written: v2 whenever there is an identity. v1 is only ever read.
    public var base64: String {
        var bytes = external
        if let identity { bytes.append(identity.bytes) }
        return bytes.base64EncodedString()
    }

    /// Written before identities existed. The key material is intact.
    public var needsMigration: Bool { identity == nil }
}
