import Foundation

/// What a v2 account keeps in the key's large-blob store: its kind, and for a portable
/// account its mask.
///
/// Every v2 account has one, a local account included. Without that, "no record" would mean
/// "local", and a portable account whose record was lost would silently derive from the
/// wrong path — passwords that look right and are not. With a record for every account, a
/// missing one is a fault the app can name.
///
/// The layout is frozen, and it is a fixed layout rather than a map with optional fields
/// on purpose: any field added later — a per-account password policy, say — changes what
/// the account derives, so an older build that ignored it would derive the wrong thing. A
/// version byte it refuses is the correct behaviour, and it comes for free.
///
/// ```
/// byte 0        0x01                 record version
/// byte 1        0x00 local · 0x01 portable
/// bytes 2..33   mask, 32 bytes       portable only
/// ```
///
/// Two or thirty-four bytes; anything else is not a record. The platform — libfido2 here,
/// the browser elsewhere — compresses and encrypts it under the credential's own large-blob
/// key; this is the plaintext.
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
