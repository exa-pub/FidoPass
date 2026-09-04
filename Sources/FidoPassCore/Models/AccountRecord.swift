import Foundation

/// Frozen v2 record: version byte 0x01, kind byte (0 local / 1 portable), then a 32-byte
/// mask for portable accounts. Exactly 2 or 34 bytes, before large-blob compression/encryption.
/// Local accounts also require a record: missing data must not silently select a derivation.
public struct AccountRecord: Hashable, Sendable {
    public static let version: UInt8 = 1
    public static let maskByteCount = 32

    public let kind: AccountKind
    /// Present exactly when `kind == .portable`.
    public let mask: Data?

    public init?(kind: AccountKind, mask: Data?) {
        switch kind {
        case .local:
            guard mask == nil else { return nil }
        case .portable:
            guard let mask, mask.count == Self.maskByteCount else { return nil }
        }
        self.kind = kind
        self.mask = mask.map { Data($0) }
    }

    /// Strict: the version, the kind byte and the length all have to be exactly right.
    public init?(decoding bytes: Data) {
        let bytes = Data(bytes)
        guard bytes.count >= 2, bytes[0] == Self.version else { return nil }
        switch bytes[1] {
        case 0x00:
            guard bytes.count == 2 else { return nil }
            self.init(kind: .local, mask: nil)
        case 0x01:
            guard bytes.count == 2 + Self.maskByteCount else { return nil }
            self.init(kind: .portable, mask: bytes.suffix(Self.maskByteCount))
        default:
            return nil
        }
    }

    public var encoded: Data {
        var bytes = Data([Self.version, kind == .portable ? 0x01 : 0x00])
        if let mask { bytes.append(mask) }
        return bytes
    }
}
