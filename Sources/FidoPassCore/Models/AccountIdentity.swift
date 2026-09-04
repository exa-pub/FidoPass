import Foundation
import CryptoKit

/// Public 16-byte identity: user.id in v2, derived from credential ID for v1 local,
/// absent for v1 portable. It affects the message locator, not password or key-pair derivation.
public struct AccountIdentity: Hashable, Sendable {
    public static let byteCount = 16

    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == Self.byteCount else { return nil }
        // Copied, so a slice of a larger buffer does not keep its indices.
        self.bytes = Data(bytes)
    }

    /// Parses the human form. The separators people put between groups — spaces, dashes,
    /// colons — and either case are accepted; a sign, a prefix or any other character is not.
    public init?(hex: String) {
        let cleaned = hex.filter { !$0.isWhitespace && $0 != "-" && $0 != ":" }
        guard cleaned.count == Self.byteCount * 2, cleaned.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = Data(capacity: Self.byteCount)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes: bytes)
    }

    /// 32 lowercase hex characters.
    public var hex: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The hex in groups of four — how it is shown, and how it is read out to someone.
    public var groupedHex: String {
        let flat = hex
        return stride(from: 0, to: flat.count, by: 4).map { offset in
            let start = flat.index(flat.startIndex, offsetBy: offset)
            let end = flat.index(start, offsetBy: 4)
            return String(flat[start..<end])
        }.joined(separator: " ")
    }

    public static func random() -> AccountIdentity {
        AccountIdentity(bytes: CryptoHelpers.randomBytes(count: byteCount))!
    }

    /// The identity of a v1 local account: the first sixteen bytes of SHA-256 over its
    /// credential id. Deterministic, so it needs no storage and survives every reconnect.
    public static func derived(fromCredentialId credentialId: Data) -> AccountIdentity {
        AccountIdentity(bytes: Data(SHA256.hash(data: credentialId)).prefix(byteCount))!
    }
}

/// Encoded as its hex string, so an inventory export shows `"a1b2c3…"` rather than a base64
/// blob that looks like key material.
extension AccountIdentity: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let parsed = AccountIdentity(hex: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a 16-byte hex identity")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}
