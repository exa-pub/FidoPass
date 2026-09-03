import Foundation

/// The `user.name` of a portable account in the v1 layout: its masked master key, base64.
///
/// `external` is the imported master key XOR-ed with a component derived from the
/// credential, so it is useless without the key that produced it. Recombining the two
/// yields the master key, which is what lets a second authenticator reproduce the same
/// passwords.
///
/// Read only. The v2 layout keeps the same 32 bytes in the account's record instead
/// (`AccountRecord.mask`), and nothing writes this layout any more; it is kept so that every
/// account written by a released version still reads, and so that the manager can tell key
/// material from a name and withhold it.
public struct PortablePayload: Hashable, Codable, Sendable {
    public static let externalByteCount = 32

    public let external: Data

    public init?(external: Data) {
        guard external.count == Self.externalByteCount else { return nil }
        self.external = Data(external)
    }

    /// Exactly 32 bytes of base64. Nothing else is a payload.
    public init?(base64: String) {
        guard let decoded = Data(base64Encoded: base64), decoded.count == Self.externalByteCount else { return nil }
        self.init(external: decoded)
    }

    public var base64: String {
        external.base64EncodedString()
    }
}
