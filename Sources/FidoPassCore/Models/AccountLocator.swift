import Foundation

/// Sixteen bytes that let the key find the account a message is for, without naming it.
///
/// A key link and every message sealed under it carry the same locator. On the receiving
/// side the app computes one per account on the key from the link's nonce and the account's
/// `AccountIdentity`, and the one that matches is the account to derive from — no touch is
/// spent finding it.
///
/// The identity, not the account's name, goes in: names are words like `vault` that a
/// dictionary would recover from a salted hash, while the identity is 96 random bits — and
/// it is the same on a second key that imported the account's backup, whatever that copy
/// was named. argon2id rather than a plain hash, at the owner's request, for the delay.
/// Nothing about the account can be read back out of a locator.
public struct AccountLocator: Hashable, Sendable {
    public static let byteCount = 16
    static let domain = Data("fidopass|ecies|idfp|v1".utf8)

    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = Data(bytes)
    }

    /// `argon2id(pwd = domain ‖ identity, salt = nonce)`, 16 bytes.
    static func compute(nonce: Data, identity: AccountIdentity) throws -> AccountLocator {
        guard nonce.count == EncryptionKeyURL.nonceByteCount else {
            throw FidoPassError.invalidState("Nonce must be \(EncryptionKeyURL.nonceByteCount) bytes")
        }
        let tag = try Argon2.id(password: domain + identity.bytes,
                                salt: nonce,
                                parameters: .v1,
                                outputByteCount: byteCount)
        guard let locator = AccountLocator(bytes: tag) else {
            throw FidoPassError.invalidState("argon2 returned \(tag.count) bytes")
        }
        return locator
    }
}
