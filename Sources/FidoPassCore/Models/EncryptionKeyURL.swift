import Foundation

/// Public encryption-key link: nonce, public key, account locator and payload checksum.
/// Fields and encodings follow docs/crypto.md §7.1. Compare the fingerprint with the owner;
/// a valid checksum alone cannot detect a substituted key.
public struct EncryptionKeyURL: Hashable, Sendable {
    public static let host = "hpkev1"
    public static let nonceByteCount = 32
    public static let publicKeyByteCount = 32
    static let checksumField = "keyfp"

    /// A fresh nonce — a fresh key. Made by the caller, not the core, so a test can pin one.
    public static func randomNonce() -> Data {
        CryptoHelpers.randomBytes(count: nonceByteCount)
    }

    public let nonce: Data
    public let publicKey: Data
    public let locator: AccountLocator
    public let fingerprint: MessageKeyFingerprint

    /// Builds the link and computes its fingerprint (one argon2id, ~10 ms).
    init(nonce: Data, publicKey: Data, locator: AccountLocator) throws {
        guard nonce.count == Self.nonceByteCount else {
            throw FidoPassError.invalidState("Nonce must be \(Self.nonceByteCount) bytes")
        }
        guard publicKey.count == Self.publicKeyByteCount else {
            throw FidoPassError.invalidState("Public key must be \(Self.publicKeyByteCount) bytes")
        }
        // The all-zero point is the one every X25519 implementation agrees is useless, and
        // the one a zeroed buffer would produce. CryptoKit refuses it again at agreement.
        guard publicKey.contains(where: { $0 != 0 }) else { throw MessageCryptoError.invalidPublicKey }
        self.nonce = Data(nonce)
        self.publicKey = Data(publicKey)
        self.locator = locator
        self.fingerprint = try MessageKeyFingerprint.compute(payload: Self.payload(nonce: nonce,
                                                                                    publicKey: publicKey,
                                                                                    locator: locator))
    }

    /// Reads either carrier with strict field order and encoding. Whitespace is ignored;
    /// scheme, host and checksum hex are case-insensitive. Prefixes throw .incomplete.
    public init(parsing text: String) throws {
        let parsed = try FidoPassLinkParser.parse(text,
                                                  host: Self.host,
                                                  fields: [.init("nonce", exactly: Self.nonceByteCount),
                                                           .init("pubkey", exactly: Self.publicKeyByteCount),
                                                           .init("idfp", exactly: AccountLocator.byteCount),
                                                           .init(Self.checksumField, hexBytes: MessageKeyFingerprint.byteCount)])
        guard let locator = AccountLocator(bytes: parsed.values[2]),
              let claimed = MessageKeyFingerprint(bytes: parsed.values[3]) else {
            throw MessageCryptoError.notFidoPassURL
        }
        try self.init(nonce: parsed.values[0], publicKey: parsed.values[1], locator: locator)
        // What was pasted has to be what this link writes: upper case, a stray character
        // between the fields — anything at all — and it is not a FidoPass link. The
        // checksum's own hex may be either case; it was compared as bytes.
        guard parsed.payload.dropLast(MessageKeyFingerprint.byteCount * 2) == payload + "&\(Self.checksumField)=" else {
            throw MessageCryptoError.notFidoPassURL
        }
        guard fingerprint == claimed else { throw MessageCryptoError.checksumMismatch }
    }

    /// The payload without its checksum — what the fingerprint is computed over, and what is
    /// the same in every carrier.
    public var payload: String {
        Self.payload(nonce: nonce, publicKey: publicKey, locator: locator)
    }

    /// The whole link, checksum included, in the carrier the app writes. What is shown,
    /// copied and sent.
    public var absoluteString: String {
        absoluteString(carrier: .written)
    }

    /// The whole link in a given carrier.
    public func absoluteString(carrier: LinkCarrier) -> String {
        carrier.prefix + payload + "&\(Self.checksumField)=" + fingerprint.hex
    }

    private static func payload(nonce: Data, publicKey: Data, locator: AccountLocator) -> String {
        "\(host)?nonce=\(Base64URL.encode(nonce))&pubkey=\(Base64URL.encode(publicKey))&idfp=\(Base64URL.encode(locator.bytes))"
    }
}
