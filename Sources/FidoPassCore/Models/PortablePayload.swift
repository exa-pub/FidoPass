import Foundation

/// Key material a portable account carries on the authenticator.
///
/// `external` is the imported master key XOR-ed with a component derived from this
/// authenticator, so it is useless without the key that produced it. Recombining the two
/// yields the master key, which is what lets a second authenticator reproduce the same
/// passwords.
public struct PortablePayload: Hashable, Codable, Sendable {
    public static let externalByteCount = 32

    public let external: Data

    public init?(external: Data) {
        guard external.count == Self.externalByteCount else { return nil }
        self.external = external
    }

    public init?(base64: String) {
        guard let decoded = Data(base64Encoded: base64) else { return nil }
        self.init(external: decoded)
    }

    public var base64: String { external.base64EncodedString() }
}
