import XCTest
@testable import FidoPassAppKit
import FidoPassCore
import TestSupport

/// A `fidopass://` link from the system is untrusted input; it is sorted with the same
/// strict readers a pasted one goes through, and nothing else.
final class IncomingLinkTests: XCTestCase {

    private let backend = MockKeyBackend()
    private let vault = AccountHandle.fixture(id: "vault", devicePath: "/dev/one")

    func testAKeyLinkIsAKey() async throws {
        let key = try backend.encryptionKey(for: vault)
        let link = await IncomingLink.classify(key.absoluteString, sealer: backend.messages)
        XCTAssertEqual(link, .encryptionKey(key))
    }

    func testAMessageLinkIsAMessage() async throws {
        let message = try backend.sealedMessage("hello", for: vault)
        let link = await IncomingLink.classify(message.absoluteString, sealer: backend.messages)
        XCTAssertEqual(link, .sealedMessage(message))
    }

    func testForeignAndBrokenLinksAreNamed() async throws {
        let key = try backend.encryptionKey(for: vault)
        let sealer = backend.messages
        let foreign = await IncomingLink.classify("https://example.org/?nonce=abc", sealer: sealer)
        XCTAssertEqual(foreign, .unrecognised(.notFidoPassURL))

        let newer = await IncomingLink.classify(key.absoluteString.replacingOccurrences(of: "keyv1", with: "keyv2"), sealer: sealer)
        XCTAssertEqual(newer, .unrecognised(.unsupportedVersion("keyv2")))

        let stripped = await IncomingLink.classify(key.canonical, sealer: sealer)
        XCTAssertEqual(stripped, .unrecognised(.checksumMissing))

        let message = try backend.sealedMessage("hello", for: vault)
        let truncated = await IncomingLink.classify(String(message.absoluteString.prefix(100)), sealer: sealer)
        XCTAssertEqual(truncated, .unrecognised(.incomplete))
    }

    /// The system hands over a `URL`; what comes out of it has to be the link, fragment and
    /// all — a percent-encoded or fragment-less rendering would fail the checksum.
    func testTheLinkSurvivesBeingAURL() throws {
        let key = try backend.encryptionKey(for: vault)
        let url = try XCTUnwrap(URL(string: key.absoluteString))
        XCTAssertEqual(url.absoluteString, key.absoluteString)
        XCTAssertEqual(url.scheme, "fidopass")
        XCTAssertEqual(url.host, "keyv1")
        let message = try backend.sealedMessage("hello", for: vault)
        XCTAssertEqual(try XCTUnwrap(URL(string: message.absoluteString)).absoluteString, message.absoluteString)
    }
}
