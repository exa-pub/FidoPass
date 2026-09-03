import XCTest
@testable import FidoPassCore

final class SealedMessageURLTests: XCTestCase {

    private func failure(_ text: String) -> MessageCryptoError? {
        do {
            _ = try SealedMessageURL(parsing: text)
            return nil
        } catch {
            return error as? MessageCryptoError
        }
    }

    private func message(_ text: String = "hello") throws -> SealedMessageURL {
        try MessageSealer().seal(text, for: try MessageFixtures.url())
    }

    func testShape() throws {
        let sealed = try message("hello")
        let text = sealed.absoluteString
        XCTAssertTrue(text.hasPrefix("fidopass://blobv1?nonce="))
        XCTAssertTrue(text.contains("&idfp="))
        XCTAssertTrue(text.contains("&content="))
        XCTAssertFalse(text.contains("#"))
        XCTAssertEqual(sealed.content.count, 32 + 5 + 16, "encapsulated key, ciphertext, tag")
        XCTAssertEqual(sealed.encapsulatedKey.count, 32)
        XCTAssertEqual(sealed.ciphertext.count, 5 + 16)
    }

    func testRoundTrip() throws {
        let sealed = try message()
        XCTAssertEqual(try SealedMessageURL(parsing: sealed.absoluteString), sealed)
        XCTAssertEqual(try SealedMessageURL(parsing: "  " + sealed.absoluteString.replacingOccurrences(of: "&", with: "\n&") + "\n"),
                       sealed, "whitespace inside is ignored")
    }

    func testEmptyTextIsAMessageOfItsOwn() throws {
        let sealed = try message("")
        XCTAssertEqual(sealed.content.count, SealedMessageURL.minimumContentByteCount)
        XCTAssertEqual(sealed.absoluteString.count, 168)
        XCTAssertEqual(try SealedMessageURL(parsing: sealed.absoluteString), sealed)
    }

    /// Up to the shortest possible message every prefix is incomplete. Past it, a prefix cut
    /// on a byte boundary is a shorter valid message — content has no fixed length, so the
    /// syntax cannot tell a truncated paste from a short one; the AEAD tag does, after the
    /// touch. What must never happen is a prefix reading as *wrong*.
    func testEveryPrefixIsIncompleteOrAShorterMessage() throws {
        let text = try message("a somewhat longer message, so that there is something to cut").absoluteString
        let shortestMessage = 168
        for length in 0..<text.count {
            let result = failure(String(text.prefix(length)))
            if length < shortestMessage {
                XCTAssertEqual(result, .incomplete, "prefix of \(length) characters")
            } else {
                XCTAssertTrue(result == nil || result == .incomplete, "prefix of \(length) characters: \(String(describing: result))")
            }
        }
    }

    func testAKeyIsNamedAsSuch() throws {
        XCTAssertEqual(failure(try MessageFixtures.url().absoluteString), .unexpectedKind("keyv1"))
    }

    func testANewerFormatIsNamed() throws {
        let text = try message().absoluteString.replacingOccurrences(of: "blobv1", with: "blobv3")
        XCTAssertEqual(failure(text), .unsupportedVersion("blobv3"))
    }

    func testTooShortContentIsNotAMessage() throws {
        let sealed = try message()
        let short = Base64URL.encode(sealed.content.prefix(47))
        let text = "fidopass://blobv1?nonce=\(Base64URL.encode(sealed.nonce))&idfp=\(Base64URL.encode(sealed.locator.bytes))&content=\(short)"
        // Without a fragment the last field may still be growing, so this is "incomplete"
        // rather than "wrong" — the syntax cannot tell a truncated paste from a pause.
        XCTAssertEqual(failure(text), .incomplete)
        XCTAssertThrowsError(try SealedMessageURL(nonce: sealed.nonce, locator: sealed.locator, content: sealed.content.prefix(47)))
    }

    func testFragmentAndForeignLinksAreRefused() throws {
        let text = try message().absoluteString
        XCTAssertEqual(failure(text + "#x"), .notFidoPassURL)
        XCTAssertEqual(failure("https://example.org/" + text), .notFidoPassURL)
        XCTAssertEqual(failure(text.uppercased()), .notFidoPassURL)
    }
}
