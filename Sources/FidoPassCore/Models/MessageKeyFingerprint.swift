import Foundation

/// Six bytes that stand for an encryption key: shown as six emoji, written as twelve hex
/// digits after `#keyfp=` in the key's link.
///
/// argon2id over the canonical link text, deliberately slow: 48 bits is short enough to
/// compare by eye and, at ~10 ms and 32 MiB per attempt, long enough that nobody forges a
/// key with the same six emoji. The same trick as Signal's safety numbers.
///
/// The fragment is a checksum, not a signature — whoever replaces the public key can
/// recompute it. What protects against substitution is the person comparing the emoji with
/// the key's owner over another channel, and the UI says so.
public struct MessageKeyFingerprint: Hashable, Sendable {
    public static let byteCount = 6
    /// Fixed and printable, so the fingerprint can be checked with the `argon2` command-line
    /// tool without decoding anything:
    /// `printf '%s' '<link before #>' | argon2 fidopass-keyfp-v1 -id -t 1 -m 15 -p 1 -l 6 -r`
    static let salt = Data("fidopass-keyfp-v1".utf8)

    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = Data(bytes)
    }

    public init?(hex: String) {
        guard hex.count == Self.byteCount * 2,
              hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = Data(capacity: Self.byteCount)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes: bytes)
    }

    /// The fingerprint of a link in canonical form — everything before the `#`.
    static func compute(canonical: String) throws -> MessageKeyFingerprint {
        let tag = try Argon2.id(password: Data(canonical.utf8),
                                salt: salt,
                                parameters: .v1,
                                outputByteCount: byteCount)
        guard let fingerprint = MessageKeyFingerprint(bytes: tag) else {
            throw FidoPassError.invalidState("argon2 returned \(tag.count) bytes")
        }
        return fingerprint
    }

    /// Twelve lowercase hex digits.
    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// One emoji per byte, ready to draw — see `EmojiAlphabet.displayString(for:)`.
    public var emojiCharacters: [String] { bytes.map(EmojiAlphabet.displayString(for:)) }

    public var emoji: String { emojiCharacters.joined() }
}
