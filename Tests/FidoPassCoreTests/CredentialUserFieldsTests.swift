import XCTest
@testable import FidoPassCore

/// CTAP offers a credential only two free-form strings, so portable accounts have to pack
/// three things — account id, display name and exported key material — into them.
///
/// The layout changed: the payload moved out of `name` and into a prefixed `displayName`,
/// leaving `name` as the machine identifier for every kind. Credentials written by the
/// previous layout are on users' keys right now, and losing their payload would make the
/// passwords derived from them unreproducible, so reading must accept both.
final class CredentialUserFieldsTests: XCTestCase {

    private let payload = Data(repeating: 0xA7, count: PortablePayload.externalByteCount)

    func testCurrentLayoutIsRead() {
        let decoded = EnrollmentService.decodeUserFields(kind: .portable,
                                                         name: "acct",
                                                         displayName: "fp-ext:v1:" + payload.base64EncodedString())
        XCTAssertEqual(decoded.portable?.external, payload)
    }

    /// Previous layout: raw base64 payload in `name`, account id in `displayName`.
    func testLegacyLayoutIsStillRead() {
        let decoded = EnrollmentService.decodeUserFields(kind: .portable,
                                                         name: payload.base64EncodedString(),
                                                         displayName: "acct")
        XCTAssertEqual(decoded.portable?.external, payload,
                       "portable accounts enrolled by the previous layout must keep working")
    }

    func testLocalAccountsCarryNoPayload() {
        let decoded = EnrollmentService.decodeUserFields(kind: .local,
                                                         name: "acct",
                                                         displayName: "Work vault")
        XCTAssertNil(decoded.portable)
        XCTAssertEqual(decoded.displayName, "Work vault")
    }

    /// A display name that merely looks like base64 must not be mistaken for key material.
    func testLocalDisplayNameIsNeverParsedAsPayload() {
        let decoded = EnrollmentService.decodeUserFields(kind: .local,
                                                         name: payload.base64EncodedString(),
                                                         displayName: payload.base64EncodedString())
        XCTAssertNil(decoded.portable)
    }

    func testPortableWithUnreadablePayloadDoesNotCrash() {
        let decoded = EnrollmentService.decodeUserFields(kind: .portable,
                                                         name: "not-base64!",
                                                         displayName: "not-base64!")
        XCTAssertNil(decoded.portable)
    }

    /// Wrong-sized material is rejected rather than silently truncated or padded.
    func testPayloadLengthIsEnforced() {
        XCTAssertNil(PortablePayload(external: Data(repeating: 0x01, count: 31)))
        XCTAssertNil(PortablePayload(external: Data(repeating: 0x01, count: 33)))
        XCTAssertNotNil(PortablePayload(external: Data(repeating: 0x01, count: 32)))
        XCTAssertNil(PortablePayload(base64: "definitely not base64 %%%"))
    }

    func testAccountKindRoundTripsThroughRpId() {
        for kind in AccountKind.allCases {
            XCTAssertEqual(AccountKind(rpId: kind.rpId), kind)
        }
        XCTAssertNil(AccountKind(rpId: "example.com"))
    }

    /// The same account id on two authenticators is a backup, not a duplicate: the two
    /// entries must stay distinguishable to list selection.
    func testAccountIdentityIncludesDevice() {
        let first = Account.fixture(id: "vault", devicePath: "/dev/one")
        let second = Account.fixture(id: "vault", devicePath: "/dev/two")
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.hashValue, second.hashValue)
        XCTAssertEqual(first, Account.fixture(id: "vault", devicePath: "/dev/one"))
    }
}

/// Regression tests for the credential's display-name field.
///
/// An empty display name is rejected by libfido2 with `FIDO_ERR_INVALID_LENGTH` before the
/// request reaches the authenticator, so enrolment fails instantly with an error that names
/// no cause. Accounts are routinely created without a display name, which made this the
/// default path rather than an edge case.
extension CredentialUserFieldsTests {

    /// The wire layout is an interoperability contract, not an internal detail: earlier
    /// releases are still installed and read the portable payload from `name`. Writing it
    /// anywhere else makes accounts created here fail in those versions with
    /// "Portable userName must contain base64 External (32 bytes)".
    func testPortablePayloadIsWrittenWhereEveryVersionLooksForIt() {
        let payload = PortablePayload(external: Data(repeating: 0x5A, count: 32))!
        let name = EnrollmentService.credentialName(kind: .portable,
                                                              accountId: "vault",
                                                              portable: payload)
        XCTAssertEqual(name, payload.base64, "the payload belongs in the name field")
        XCTAssertEqual(Data(base64Encoded: name)?.count, 32,
                       "older versions require exactly 32 base64-decoded bytes here")

        let display = EnrollmentService.credentialDisplayName(kind: .portable,
                                                                        accountId: "vault",
                                                                        displayName: "",
                                                                        portable: payload)
        XCTAssertEqual(display, "vault", "the account id goes in displayName for portable accounts")
    }

    func testLocalAccountKeepsTheAccountIdInName() {
        XCTAssertEqual(EnrollmentService.credentialName(kind: .local,
                                                                  accountId: "vault",
                                                                  portable: nil),
                       "vault")
    }

    /// Before the payload exists — during `makeCredential`, ahead of the second touch —
    /// there is nothing to write, and the fields must still be valid.
    func testPortableWithoutPayloadYetFallsBackToTheAccountId() {
        XCTAssertEqual(EnrollmentService.credentialName(kind: .portable,
                                                                  accountId: "vault",
                                                                  portable: nil),
                       "vault")
    }

    /// Round trip through the layout that is actually written.
    func testWrittenLayoutReadsBack() {
        let payload = PortablePayload(external: Data(repeating: 0x37, count: 32))!
        let name = EnrollmentService.credentialName(kind: .portable, accountId: "vault", portable: payload)
        let display = EnrollmentService.credentialDisplayName(kind: .portable,
                                                                        accountId: "vault",
                                                                        displayName: "",
                                                                        portable: payload)
        XCTAssertEqual(EnrollmentService.decodeUserFields(kind: .portable, name: name, displayName: display).portable,
                       payload)
    }

    func testDisplayNameIsNeverEmpty() {
        for kind in AccountKind.allCases {
            for payload in [nil, PortablePayload(external: Data(repeating: 0x11, count: 32))] {
                let value = EnrollmentService.credentialDisplayName(kind: kind,
                                                                              accountId: "vault",
                                                                              displayName: "",
                                                                              portable: payload)
                XCTAssertFalse(value.isEmpty, "\(kind) enrolment would fail with FIDO_ERR_INVALID_LENGTH")
            }
        }
    }

    func testExplicitDisplayNameWins() {
        let value = EnrollmentService.credentialDisplayName(kind: .local,
                                                                      accountId: "vault",
                                                                      displayName: "Work vault",
                                                                      portable: nil)
        XCTAssertEqual(value, "Work vault")
    }

    /// Builds between the refactor and this fix put a prefixed payload in `displayName`.
    /// Those accounts exist on real keys and must keep opening.
    func testPrefixedInterimLayoutIsStillAccepted() {
        let payload = PortablePayload(external: Data(repeating: 0x5A, count: 32))!
        let decoded = EnrollmentService.decodeUserFields(kind: .portable,
                                                         name: "vault",
                                                         displayName: "fp-ext:v1:" + payload.base64)
        XCTAssertEqual(decoded.portable, payload)
    }
}
