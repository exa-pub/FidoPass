import Foundation
import CryptoKit

/// Every salt an assertion is made under — one place, because the salts are the contract.
///
/// Two families. The v1 salts are plain SHA-256 over a domain string and the inputs, and
/// they are frozen: a v1 account derives with them for as long as it exists. The v2 salts
/// go through `prfSalt`, which is the wrapping WebAuthn's `prf` extension applies before
/// handing a salt to the authenticator — so a browser page, which can only reach the key
/// through that extension, gets the same 32 bytes back that this app does. That wrapping
/// is the one thing the app and a browser could disagree on silently, and it is pinned by
/// vector in `SaltFactoryTests`.
enum SaltFactory {
    private static let residentPrefix = Data("fidopass|salt|".utf8)
    private static let fixedChallenge = Data("fidopass|fixed-challenge|v1".utf8)
    private static let portableLabelPrefix = Data("fidopass|portable|".utf8)
    // Message keys live in their own domain: nothing derived for a message shares a salt
    // with anything derived for a password.
    private static let messageKeyPrefix = Data("fidopass|ecies|salt|v1".utf8)
    private static let portableMessagePrefix = Data("fidopass|ecies|portable|v1".utf8)

    // v2: the inputs a browser would pass to `prf.eval`, before the PRF wrapping.
    private static let prfPrefix = Data("WebAuthn PRF".utf8) + Data([0x00])
    private static let localPasswordPrefixV2 = Data("fidopass|pw|v2|".utf8)
    private static let messageKeyPrefixV2 = Data("fidopass|ecies|v2|".utf8)
    private static let fixedChallengeV2 = Data("fidopass|fixed|v2".utf8)

    // MARK: - v1

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

    /// The hmac-secret salt a v1 local account's message key is derived under.
    static func messageKeySalt(nonce: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: messageKeyPrefix)
        hasher.update(data: nonce)
        return Data(hasher.finalize())
    }

    // MARK: - Portable, both formats

    /// The HMAC message a portable account's password is derived under, keyed by the master
    /// key. Format-independent: this is what lets a migrated account keep its passwords.
    static func portableLabelSalt(_ label: String) -> Data {
        var hasher = SHA256()
        hasher.update(data: portableLabelPrefix)
        hasher.update(data: Data(label.utf8))
        return Data(hasher.finalize())
    }

    /// The HMAC message a portable account's message key is derived under, keyed by the
    /// master key — the counterpart of `portableLabelSalt` for messages. Format-independent
    /// for the same reason.
    static func portableMessageSalt(nonce: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: portableMessagePrefix)
        hasher.update(data: nonce)
        return Data(hasher.finalize())
    }

    // MARK: - v2

    /// What the authenticator receives when a browser evaluates `prf` over `input`:
    /// `SHA-256("WebAuthn PRF" ‖ 0x00 ‖ input)`. Every v2 salt is made this way so that the
    /// app and a page ask the key the same question.
    static func prfSalt(input: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: prfPrefix)
        hasher.update(data: input)
        return Data(hasher.finalize())
    }

    /// The v2 local password salt. The label and a fixed-width revision, nothing else: the
    /// credential's own secret already makes it unique, and keeping the name out of the salt
    /// is what lets the name be a name.
    static func localPasswordSalt(label: String, revision: Int) -> Data {
        var input = localPasswordPrefixV2
        input.append(Data(label.utf8))
        input.append(withUnsafeBytes(of: UInt32(revision).bigEndian) { Data($0) })
        return prfSalt(input: input)
    }

    /// The v2 local message-key salt.
    static func messageKeySaltV2(nonce: Data) -> Data {
        prfSalt(input: messageKeyPrefixV2 + nonce)
    }

    /// The v2 fixed-component salt: a constant, so one touch recovers the mask's other half.
    static func fixedComponentSaltV2() -> Data {
        prfSalt(input: fixedChallengeV2)
    }

    // MARK: - By format

    static func fixedComponentSalt(format: AccountFormat) -> Data {
        switch format {
        case .v1: return fixedComponentSalt()
        case .v2: return fixedComponentSaltV2()
        }
    }

    static func messageKeySalt(nonce: Data, format: AccountFormat) -> Data {
        switch format {
        case .v1: return messageKeySalt(nonce: nonce)
        case .v2: return messageKeySaltV2(nonce: nonce)
        }
    }
}
