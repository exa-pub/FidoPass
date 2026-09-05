import Foundation

/// Read-only v1 portable mask: base64(master XOR credential fixed component).
/// V2 stores these 32 bytes in AccountRecord instead.
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
