import Foundation

/// Public 16-byte locator derived from account identity and message nonce.
/// Locating uses enumerated identities without touching the authenticator. See docs/crypto.md §6.3.
public struct AccountLocator: Hashable, Sendable {
    public static let byteCount = 16
    static let domain = Data("fidopass|hpke|idfp|v1".utf8)

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
