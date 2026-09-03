import Foundation
@testable import FidoPassCore

/// One key, built from fixed bytes, for every test that needs a link or a message.
enum MessageFixtures {
    static let nonce = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
    static let otherNonce = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) })
    static let privateKey = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 5 &+ 11) })
    static let identity = AccountIdentity(hex: "0102030405060708090a0b0c0d0e0f10")!

    static func locator(nonce: Data = nonce) throws -> AccountLocator {
        try AccountLocator.compute(nonce: nonce, identity: identity)
    }

    static func url(nonce: Data = nonce, privateKey: Data = privateKey) throws -> EncryptionKeyURL {
        try EncryptionKeyURL(nonce: nonce,
                             publicKey: try MessageKey.publicKey(for: privateKey),
                             locator: try locator(nonce: nonce))
    }

    static func key(nonce: Data = nonce, privateKey: Data = privateKey) throws -> MessageKey {
        MessageKey(url: try url(nonce: nonce, privateKey: privateKey), privateKey: privateKey)
    }
}
