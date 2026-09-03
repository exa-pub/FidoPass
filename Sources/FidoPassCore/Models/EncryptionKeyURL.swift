import Foundation

/// An encryption key as it is handed around: a link anyone can seal a message under.
///
/// ```
/// fidopass://keyv1?nonce=<43>&pubkey=<43>&idfp=<22>#keyfp=<12 hex>
/// ```
///
/// Everything in it is public. The nonce is what the private key is re-derived from on the
/// authenticator, the public key is what a sender encrypts to, the locator finds the account
/// without naming it, and the fragment is the fingerprint of the rest — the six emoji the
/// owner and the sender compare, and a checksum against a link mangled in transit.
///
/// Canonical form is the only form: fields in this order, base64url without padding, lower
/// case, nothing else. `init(parsing:)` re-serialises what it read and refuses anything that
/// does not come back identical, then checks the fingerprint. Not `Codable` and without a
/// `description`: not because it is secret — it is not — but so that a 164-character link
/// never ends up inside an error message by accident.
public struct EncryptionKeyURL: Hashable, Sendable {
    public static let host = "keyv1"
    public static let nonceByteCount = 32
    public static let publicKeyByteCount = 32
    static let fragmentPrefix = "keyfp="

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
        self.fingerprint = try MessageKeyFingerprint.compute(canonical: Self.canonical(nonce: nonce,
                                                                                        publicKey: publicKey,
                                                                                        locator: locator))
    }

    /// Reads a link someone pasted. Whitespace is ignored; everything else has to be exact.
    ///
    /// Throws `MessageCryptoError` — `.incomplete` for every prefix of a valid link, so that a
    /// field being typed into can stay quiet; the other cases name what is wrong.
    public init(parsing text: String) throws {
        let parsed = try FidoPassLinkParser.parse(text,
                                                  host: Self.host,
                                                  fields: [.init("nonce", exactly: Self.nonceByteCount),
                                                           .init("pubkey", exactly: Self.publicKeyByteCount),
                                                           .init("idfp", exactly: AccountLocator.byteCount)])
        guard let fragment = parsed.fragment else { throw MessageCryptoError.checksumMissing }
        guard fragment.hasPrefix(Self.fragmentPrefix) else {
            if Self.fragmentPrefix.hasPrefix(fragment) { throw MessageCryptoError.incomplete }
            throw MessageCryptoError.notFidoPassURL
        }
        let hex = fragment.dropFirst(Self.fragmentPrefix.count).lowercased()
        guard hex.allSatisfy(\.isHexDigit), hex.count <= MessageKeyFingerprint.byteCount * 2 else {
            throw MessageCryptoError.notFidoPassURL
        }
        guard hex.count == MessageKeyFingerprint.byteCount * 2 else { throw MessageCryptoError.incomplete }

        guard let locator = AccountLocator(bytes: parsed.values[2]) else { throw MessageCryptoError.notFidoPassURL }
        try self.init(nonce: parsed.values[0], publicKey: parsed.values[1], locator: locator)
        // What was pasted has to be what this link writes: upper case, a stray character
        // between the fields — anything at all — and it is not a FidoPass link.
        guard canonical == parsed.body else { throw MessageCryptoError.notFidoPassURL }
        guard fingerprint.hex == hex else { throw MessageCryptoError.checksumMismatch }
    }

    /// The link without its fragment — what the fingerprint is computed over.
    public var canonical: String {
        Self.canonical(nonce: nonce, publicKey: publicKey, locator: locator)
    }

    /// The whole link, fragment included. What is shown, copied and sent.
    public var absoluteString: String {
        canonical + "#" + Self.fragmentPrefix + fingerprint.hex
    }

    private static func canonical(nonce: Data, publicKey: Data, locator: AccountLocator) -> String {
        "\(FidoPassLinkParser.scheme)\(host)?nonce=\(Base64URL.encode(nonce))&pubkey=\(Base64URL.encode(publicKey))&idfp=\(Base64URL.encode(locator.bytes))"
    }
}
