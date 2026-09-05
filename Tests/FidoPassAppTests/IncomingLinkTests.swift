import XCTest
@testable import FidoPassAppKit
import FidoPassCore
import TestSupport

/// A `fidopass://` link from the system is untrusted input; it is sorted with the same
/// strict readers a pasted one goes through, and nothing else.
final class IncomingLinkTests: AppTestCase {

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

        let newer = await IncomingLink.classify(key.absoluteString.replacingOccurrences(of: "hpkev1", with: "hpkev2"), sealer: sealer)
        XCTAssertEqual(newer, .unrecognised(.unsupportedVersion("hpkev2")))

        let stripped = await IncomingLink.classify(LinkCarrier.web.prefix + key.payload, sealer: sealer)
        XCTAssertEqual(stripped, .unrecognised(.incomplete))

        let message = try backend.sealedMessage("hello", for: vault)
        let truncated = await IncomingLink.classify(String(message.absoluteString.prefix(100)), sealer: sealer)
        XCTAssertEqual(truncated, .unrecognised(.incomplete))
    }

    /// The system hands over a `URL`; what comes out of it has to be the link, checksum and
    /// all — a percent-encoded rendering would fail the checksum. The system delivers the
    /// `fidopass://` form; the web form survives the same trip, with the payload as its
    /// fragment.
    func testTheLinkSurvivesBeingAURL() throws {
        let key = try backend.encryptionKey(for: vault)
        let app = try XCTUnwrap(URL(string: key.absoluteString(carrier: .app)))
        XCTAssertEqual(app.absoluteString, key.absoluteString(carrier: .app))
        XCTAssertEqual(app.scheme, "fidopass")
        XCTAssertEqual(app.host, "hpkev1")

        let web = try XCTUnwrap(URL(string: key.absoluteString))
        XCTAssertEqual(web.absoluteString, key.absoluteString)
        XCTAssertEqual(web.scheme, "https")
        XCTAssertEqual(web.host, "fidopass.org")
        XCTAssertEqual(web.path, "/link")
        XCTAssertEqual(web.fragment, key.payload + "&keyfp=" + key.fingerprint.hex, "the payload is the fragment and nothing else")
        XCTAssertNil(web.query)

        let message = try backend.sealedMessage("hello", for: vault)
        XCTAssertEqual(try XCTUnwrap(URL(string: message.absoluteString)).absoluteString, message.absoluteString)
        XCTAssertEqual(try XCTUnwrap(URL(string: message.absoluteString(carrier: .app))).host, "hpkeblobv1")
    }
}

@MainActor
extension IncomingLinkTests {
    func testMessageArrivingWithoutKeyMustSurviveConnection() async throws {
        let backend = MockKeyBackend()
        let panel = AppTestFactory.makeStore(backend: backend)
        await panel.prepareForDisplay()
        let device = MockKeyBackend.device()
        let account = Account.fixture(id: "vault", kind: .local)
        let handle = AccountHandle(account: account, devicePath: device.path)
        let message = try backend.sealedMessage("public sample", for: handle)
        panel.handleLink(.sealedMessage(message))
        backend.devices = [device]
        backend.accountsByPath[device.path] = [account]
        backend.pins[device.path] = "1234"
        await panel.prepareForDisplay()
        panel.pinDraft = "1234"
        await panel.submitPin()
        let router = panel.router as! RecordingWindowRouter
        XCTAssertTrue(router.openedDecryptors.last?.message == message, "The clicked message was lost before the key arrived")
    }
}

@MainActor
extension IncomingLinkTests {
    func testLargeMessageLinkIsClassifiedWithoutKeyLinkSizeLimit() async throws {
        let backend = MockKeyBackend()
        let handle = AccountHandle.fixture(id: "vault")
        let message = try backend.sealedMessage(String(repeating: "x", count: 8_000), for: handle)
        let link = await IncomingLink.classify(message.absoluteString, sealer: backend.messages)
        if case .sealedMessage = link {} else { XCTFail("A message must not inherit the smaller key-link limit") }
    }
}
