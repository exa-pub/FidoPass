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

    /// The difference that decides whether a user dares try again: a PIN the key threw out
    /// for being weak cost nothing, while a PIN it failed to verify cost one of eight.
    func testAPinRejectedByPolicySaysNoAttemptWasSpent() {
        let message = FidoPassErrorPresenter.message(for: libfido2(.pinPolicyViolation))
        XCTAssertEqual(message.kind, .pinRejectedByKey)
        XCTAssertTrue(message.isRetryable)
        XCTAssertTrue(message.fullText().contains("No PIN attempt was used"),
                      "otherwise the user assumes they burned one of the eight")
    }

    /// Protocol-level PIN failure costs an attempt exactly as a wrong PIN does, so it is
    /// presented as one — every caller counting attempts would otherwise need to learn a
    /// second spelling of the same event.
    func testPinAuthInvalidCountsAsAWrongPin() {
        let message = FidoPassErrorPresenter.message(for: libfido2(.pinAuthInvalid))
        XCTAssertEqual(message.kind, .pinInvalid)
        XCTAssertTrue(message.fullText(retriesRemaining: 2).contains("2 attempts left"))
    }

    /// A bare refusal means "not in this state", and which state depends on what was
    /// attempted. The presenter must leave that to the caller instead of inventing it.
    func testARefusalIsRecognisedSoTheCallerCanExplainIt() {
        let message = FidoPassErrorPresenter.message(for: libfido2(.notAllowed))
        XCTAssertEqual(message.kind, .notAllowed)
        XCTAssertTrue(message.isRetryable)
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
