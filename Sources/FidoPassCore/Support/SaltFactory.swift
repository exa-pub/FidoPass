import Foundation
import CryptoKit

enum SaltFactory {
    private static let residentPrefix = Data("fidopass|salt|".utf8)
    private static let fixedChallenge = Data("fidopass|fixed-challenge|v1".utf8)
    private static let portableLabelPrefix = Data("fidopass|portable|".utf8)
    // Message keys live in their own domain: nothing derived for a message shares a salt
    // with anything derived for a password.
    private static let messageKeyPrefix = Data("fidopass|ecies|salt|v1".utf8)
    private static let portableMessagePrefix = Data("fidopass|ecies|portable|v1".utf8)

    static func residentSalt(label: String, rpId: String, accountId: String, revision: Int) -> Data {
        var hasher = SHA256()
        hasher.update(data: residentPrefix)
        hasher.update(data: Data(rpId.utf8))
        hasher.update(data: Data("|".utf8))
        hasher.update(data: Data(accountId.utf8))
        hasher.update(data: Data("|".utf8))
        hasher.update(data: Data(label.utf8))
        hasher.update(data: Data("|".utf8))
        hasher.update(data: withUnsafeBytes(of: UInt32(revision).bigEndian) { Data($0) })
        return Data(hasher.finalize())
    }

    static func fixedComponentSalt() -> Data {
        Data(SHA256.hash(data: fixedChallenge))
    }

    static func portableLabelSalt(_ label: String) -> Data {
        var hasher = SHA256()
        hasher.update(data: portableLabelPrefix)
        hasher.update(data: Data(label.utf8))
        return Data(hasher.finalize())
    }

    /// The hmac-secret salt a local account's message key is derived under.
    static func messageKeySalt(nonce: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: messageKeyPrefix)
        hasher.update(data: nonce)
        return Data(hasher.finalize())
    }

    /// The HMAC message a portable account's message key is derived under, keyed by the
    /// master key — the counterpart of `portableLabelSalt` for passwords.
    static func portableMessageSalt(nonce: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: portableMessagePrefix)
        hasher.update(data: nonce)
        return Data(hasher.finalize())
    }
}
