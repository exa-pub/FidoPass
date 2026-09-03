import XCTest
@testable import FidoPassCore

final class MessageKeyFingerprintTests: XCTestCase {

    /// The same computation `Argon2Tests` checks against the command-line tool, through the
    /// type that owns the salt and the length.
    func testComputeMatchesTheReferenceTool() throws {
        let fingerprint = try MessageKeyFingerprint.compute(canonical: "fidopass://keyv1?nonce=abc&pubkey=def&idfp=ghi")
        XCTAssertEqual(fingerprint.hex, "1c6704c8a388")
        XCTAssertEqual(fingerprint.bytes.count, MessageKeyFingerprint.byteCount)
    }

    func testEmojiAreTheBytesThroughTheAlphabet() throws {
        let fingerprint = try XCTUnwrap(MessageKeyFingerprint(bytes: Data([0, 1, 2, 255, 16, 17])))
        XCTAssertEqual(fingerprint.emojiCharacters, [0, 1, 2, 255, 16, 17].map { EmojiAlphabet.displayString(for: UInt8($0)) })
        XCTAssertEqual(fingerprint.emoji.count, 6)
        XCTAssertTrue(fingerprint.emoji.hasPrefix("👍👎👊"))
    }

    func testHexRoundTrip() throws {
        let fingerprint = try XCTUnwrap(MessageKeyFingerprint(hex: "1C6704C8A388"))
        XCTAssertEqual(fingerprint.hex, "1c6704c8a388", "lower case out, any case in")
        XCTAssertEqual(MessageKeyFingerprint(hex: fingerprint.hex), fingerprint)
    }

    func testWrongLengthsAreRefused() {
        XCTAssertNil(MessageKeyFingerprint(bytes: Data(repeating: 1, count: 5)))
        XCTAssertNil(MessageKeyFingerprint(bytes: Data(repeating: 1, count: 32)))
        XCTAssertNil(MessageKeyFingerprint(hex: "1c6704c8a3"))
        XCTAssertNil(MessageKeyFingerprint(hex: "1c6704c8a38g"))
    }

    func testSaltIsLongEnoughForArgon2() {
        XCTAssertGreaterThanOrEqual(MessageKeyFingerprint.salt.count, Argon2.minimumSaltByteCount)
        XCTAssertEqual(String(decoding: MessageKeyFingerprint.salt, as: UTF8.self), "fidopass-keyfp-v1")
    }
}
