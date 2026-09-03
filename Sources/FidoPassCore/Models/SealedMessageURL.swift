import Foundation

/// A sealed message, as a link.
///
/// ```
/// https://fidopass.org/link#hpkeblobv1?nonce=<43>&idfp=<22>&content=<base64url>    (≥ 187 chars)
/// fidopass://hpkeblobv1?nonce=<43>&idfp=<22>&content=<base64url>                   (≥ 172 chars)
/// content = enc(32) ‖ ciphertext ‖ tag(16)
/// ```
///
/// The nonce and the locator are copied from the key the message was sealed under: they are
/// what the receiving side needs to find the account and re-derive the private key. There is
/// no checksum — the AEAD tag inside `content` is the integrity check, and it can only be
/// verified after a touch — so the syntax is all that can be checked before one.
///
/// Two consequences worth knowing. Every message under one key carries the same nonce, so
/// messages to the same key are visibly to the same key; that is the price of keeping no
/// state at all on the receiving side. And an empty text still seals to a `content` of 48
/// bytes, so "an empty message" and "no message" cannot be confused.
public struct SealedMessageURL: Hashable, Sendable {
    public static let host = "hpkeblobv1"
    public static let encapsulatedKeyByteCount = 32
    public static let tagByteCount = 16
    /// An encapsulated key and a tag, around nothing.
    public static var minimumContentByteCount: Int { encapsulatedKeyByteCount + tagByteCount }

    public let nonce: Data
    public let locator: AccountLocator
    public let content: Data

    public init(nonce: Data, locator: AccountLocator, content: Data) throws {
        guard nonce.count == EncryptionKeyURL.nonceByteCount else {
            throw FidoPassError.invalidState("Nonce must be \(EncryptionKeyURL.nonceByteCount) bytes")
        }
        guard content.count >= Self.minimumContentByteCount else {
            throw FidoPassError.invalidState("Content must be at least \(Self.minimumContentByteCount) bytes")
        }
        self.nonce = Data(nonce)
        self.locator = locator
        self.content = Data(content)
    }

    /// Reads a link someone pasted, in either carrier. Whitespace is ignored; everything else
    /// has to be exact. Throws `MessageCryptoError`, `.incomplete` for every prefix of a
    /// valid link.
    public init(parsing text: String) throws {
        let parsed = try FidoPassLinkParser.parse(text,
                                                  host: Self.host,
                                                  fields: [.init("nonce", exactly: EncryptionKeyURL.nonceByteCount),
                                                           .init("idfp", exactly: AccountLocator.byteCount),
                                                           .init("content", atLeast: Self.minimumContentByteCount)])
        guard let locator = AccountLocator(bytes: parsed.values[1]) else { throw MessageCryptoError.notFidoPassURL }
        try self.init(nonce: parsed.values[0], locator: locator, content: parsed.values[2])
        guard payload == parsed.payload else { throw MessageCryptoError.notFidoPassURL }
    }

    /// Everything after the carrier — the same in every carrier.
    public var payload: String {
        "\(Self.host)?nonce=\(Base64URL.encode(nonce))&idfp=\(Base64URL.encode(locator.bytes))&content=\(Base64URL.encode(content))"
    }

    /// The whole link in the carrier the app writes.
    public var absoluteString: String {
        absoluteString(carrier: .written)
    }

    public func absoluteString(carrier: LinkCarrier) -> String {
        carrier.prefix + payload
    }

    var encapsulatedKey: Data { content.prefix(Self.encapsulatedKeyByteCount) }
    var ciphertext: Data { content.dropFirst(Self.encapsulatedKeyByteCount) }
}
