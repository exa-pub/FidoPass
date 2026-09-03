import Foundation

/// An encryption key as it is handed around: a link anyone can seal a message under.
///
/// ```
/// https://fidopass.org/link#hpkev1?nonce=<43>&pubkey=<43>&idfp=<22>&keyfp=<12 hex>    (180 chars)
/// fidopass://hpkev1?nonce=<43>&pubkey=<43>&idfp=<22>&keyfp=<12 hex>                   (165 chars)
/// ```
///
/// Everything in it is public. The nonce is what the private key is re-derived from on the
/// authenticator, the public key is what a sender encrypts to, the locator finds the account
/// without naming it, and `keyfp` is the fingerprint of the rest — the six emoji the owner
/// and the sender compare, and a checksum against a link mangled in transit. The
/// fingerprint is computed over the *payload*, `hpkev1?…` up to `&keyfp=`, which is the
/// same whichever carrier the link travels in: the emoji are a property of the key, not of
/// the link's dress.
///
/// Canonical form is the only form: fields in this order, base64url without padding, lower
/// case, nothing else. `init(parsing:)` re-serialises what it read and refuses anything that
/// does not come back identical, then checks the fingerprint. Not `Codable` and without a
/// `description`: not because it is secret — it is not — but so that a 180-character link
/// never ends up inside an error message by accident.
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

    /// Reads a link someone pasted, in either carrier. Whitespace is ignored; everything else
    /// has to be exact.
    ///
    /// Throws `MessageCryptoError` — `.incomplete` for every prefix of a valid link, so that a
    /// field being typed into can stay quiet; the other cases name what is wrong. A link
    /// that stops before its checksum is a prefix like any other: the checksum is required,
    /// but its absence is indistinguishable from a link not yet finished.
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
