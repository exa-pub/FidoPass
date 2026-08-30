import XCTest
@testable import FidoPassApp
import FidoPassCore

final class ErrorPresentationTests: XCTestCase {

    private func libfido2(_ status: FidoStatus) -> FidoPassError {
        .libfido2(operation: "dev_get_assert", status: status, message: "raw text")
    }

    func testPinInvalidIsRecognised() {
        let message = FidoPassErrorPresenter.message(for: libfido2(.pinInvalid))
        XCTAssertEqual(message.kind, .pinInvalid)
        XCTAssertTrue(message.isRetryable)
    }

    /// The countdown is the whole point of U1: a user must never spend their last attempt
    /// without being told what it costs.
    func testRemainingAttemptsAreSpelledOut() {
        let message = FidoPassErrorPresenter.message(for: libfido2(.pinInvalid))
        XCTAssertTrue(message.fullText(retriesRemaining: 5).contains("5 attempts left"))

        let lastChance = message.fullText(retriesRemaining: 1)
        XCTAssertTrue(lastChance.contains("1 attempt left"))
        XCTAssertTrue(lastChance.lowercased().contains("permanently"),
                      "the last attempt must say what happens next")
    }

    func testBlockedStatesAreDistinguished() {
        let authBlocked = FidoPassErrorPresenter.message(for: libfido2(.pinAuthBlocked))
        XCTAssertEqual(authBlocked.kind, .pinAuthBlocked)
        XCTAssertTrue(authBlocked.recovery?.lowercased().contains("plug") == true,
                      "a reconnect fixes this state and the user should be told so")

        let blocked = FidoPassErrorPresenter.message(for: libfido2(.pinBlocked))
        XCTAssertEqual(blocked.kind, .pinBlocked)
        XCTAssertFalse(blocked.isRetryable)
        XCTAssertTrue(blocked.recovery?.lowercased().contains("reset") == true)
    }

    func testRawTextIsKeptButNotLeading() {
        let message = FidoPassErrorPresenter.message(for: libfido2(.pinInvalid))
        XCTAssertEqual(message.details, "dev_get_assert: raw text")
        XCTAssertFalse(message.title.contains("dev_get_assert"),
                       "the raw operation name must not be the headline")
    }

    func testUnknownCodesStillProduceSomethingReadable() {
        let message = FidoPassErrorPresenter.message(for: libfido2(.other(-99)))
        XCTAssertEqual(message.kind, .other)
        XCTAssertFalse(message.title.isEmpty)
    }

    func testNonFidoErrorsFallBackToTheirDescription() {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        XCTAssertEqual(FidoPassErrorPresenter.message(for: Boom()).title, "boom")
    }

    func testTouchTimeoutIsRetryable() {
        let message = FidoPassErrorPresenter.message(for: libfido2(.actionTimeout))
        XCTAssertEqual(message.kind, .touchTimeout)
        XCTAssertTrue(message.isRetryable)
    }

    func testStorageFullExplainsTheWayOut() {
        let message = FidoPassErrorPresenter.message(for: libfido2(.keyStoreFull))
        XCTAssertEqual(message.kind, .storageFull)
        XCTAssertNotNil(message.recovery)
    }
}
