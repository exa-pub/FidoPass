import XCTest
@testable import FidoPassCore

/// CTAP offers a credential only two free-form strings, so a portable account has to pack
/// its account id and its exported key material into them.
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
        XCTAssertEqual(decoded?.external, payload)
    }

    /// Previous layout: raw base64 payload in `name`, account id in `displayName`.
    func testLegacyLayoutIsStillRead() {
        let decoded = EnrollmentService.decodeUserFields(kind: .portable,
                                                         name: payload.base64EncodedString(),
                                                         displayName: "acct")
        XCTAssertEqual(decoded?.external, payload,
                       "portable accounts enrolled by the previous layout must keep working")
    }

    func testLocalAccountsCarryNoPayload() {
        let decoded = EnrollmentService.decodeUserFields(kind: .local,
                                                         name: "acct",
                                                         displayName: "Work vault")
        XCTAssertNil(decoded)
    }

    /// A display name that merely looks like base64 must not be mistaken for key material.
    func testLocalDisplayNameIsNeverParsedAsPayload() {
        let decoded = EnrollmentService.decodeUserFields(kind: .local,
                                                         name: payload.base64EncodedString(),
                                                         displayName: payload.base64EncodedString())
        XCTAssertNil(decoded)
    }

    func testPortableWithUnreadablePayloadDoesNotCrash() {
        let decoded = EnrollmentService.decodeUserFields(kind: .portable,
                                                         name: "not-base64!",
                                                         displayName: "not-base64!")
        XCTAssertNil(decoded)
    }

    /// Wrong-sized material is rejected rather than silently truncated or padded.
    func testPayloadLengthIsEnforced() {
        XCTAssertNil(PortablePayload(external: Data(repeating: 0x01, count: 31)))
        XCTAssertNil(PortablePayload(external: Data(repeating: 0x01, count: 33)))
        XCTAssertNotNil(PortablePayload(external: Data(repeating: 0x01, count: 32)))
        XCTAssertNil(PortablePayload(base64: "definitely not base64 %%%"))
        // The two layouts are told apart by length alone, so every other length is nothing.
        for count in [16, 33, 43, 45, 48] {
            XCTAssertNil(PortablePayload(base64: Data(repeating: 0x01, count: count).base64EncodedString()),
                         "\(count) bytes is not a payload")
        }
        XCTAssertNotNil(PortablePayload(base64: Data(repeating: 0x01, count: 44).base64EncodedString()))
    }

    // MARK: - Layout v2: key material followed by the identity

    private let identity = AccountIdentity(bytes: Data((0..<12).map { UInt8($0 &* 5 &+ 1) }))!

    func testCurrentLayoutCarriesTheIdentity() throws {
        let written = PortablePayload(external: payload, identity: identity)!
        XCTAssertEqual(Data(base64Encoded: written.base64)?.count, 44)

        let decoded = try XCTUnwrap(EnrollmentService.decodeUserFields(kind: .portable,
                                                                       name: written.base64,
                                                                       displayName: "acct"))
        XCTAssertEqual(decoded.external, payload)
        XCTAssertEqual(decoded.identity, identity)
        XCTAssertFalse(decoded.needsMigration)
    }

    /// A payload from an earlier version has the material and nothing after it. It reads,
    /// and it says that an identity is missing rather than inventing one.
    func testPreviousLayoutReadsAsNeedingMigration() throws {
        let decoded = try XCTUnwrap(EnrollmentService.decodeUserFields(kind: .portable,
                                                                       name: payload.base64EncodedString(),
                                                                       displayName: "acct"))
        XCTAssertEqual(decoded.external, payload)
        XCTAssertNil(decoded.identity)
        XCTAssertTrue(decoded.needsMigration)
        XCTAssertTrue(Account.fixture(kind: .portable, portable: decoded).needsMigration)
    }

    /// CTAP lets an authenticator keep at most 64 bytes of `user.name`. The v2 layout is
    /// 60 characters of base64 — ASCII, so 60 bytes — and that margin is why the identity
    /// is twelve bytes and not sixteen: 48 bytes would encode to exactly 64.
    func testCurrentLayoutFitsTheCtapNameLimit() {
        let written = PortablePayload(external: payload, identity: identity)!
        let name = EnrollmentService.credentialName(kind: .portable, accountId: "vault", portable: written)
        XCTAssertEqual(name.count, 60)
        XCTAssertLessThanOrEqual(name.utf8.count, 64)
    }

    /// The identity is derived for a local account and stored for a portable one; a
    /// portable account from before identities has none.
    func testAccountIdentityPerKind() {
        let local = Account.fixture(id: "disk", kind: .local, credentialId: Data("cred".utf8))
        XCTAssertEqual(local.identity, AccountIdentity.derived(fromCredentialId: Data("cred".utf8)))
        XCTAssertFalse(local.needsMigration, "a local account never needs migrating")

        let portable = Account.fixture(kind: .portable, portable: PortablePayload(external: payload, identity: identity))
        XCTAssertEqual(portable.identity, identity)
        XCTAssertFalse(portable.needsMigration)

        let legacy = Account.fixture(kind: .portable, portable: PortablePayload(external: payload))
        XCTAssertNil(legacy.identity)
        XCTAssertTrue(legacy.needsMigration)

        let unreadable = Account.fixture(kind: .portable, portable: nil)
        XCTAssertNil(unreadable.identity)
        XCTAssertFalse(unreadable.needsMigration, "missing material is a different failure from a missing identity")
    }

    func testAccountKindRoundTripsThroughRpId() {
        for kind in AccountKind.allCases {
            XCTAssertEqual(AccountKind(rpId: kind.rpId), kind)
        }
        XCTAssertNil(AccountKind(rpId: "example.com"))
    }

    /// The same account id on two authenticators is a backup, not a duplicate: the two
    /// handles must stay distinguishable, while the record on the key is the same value.
    func testAccountIdentityIncludesDevice() {
        let first = AccountHandle.fixture(id: "vault", devicePath: "/dev/one")
        let second = AccountHandle.fixture(id: "vault", devicePath: "/dev/two")
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.hashValue, second.hashValue)
        XCTAssertEqual(first, AccountHandle.fixture(id: "vault", devicePath: "/dev/one"))
        XCTAssertEqual(first.account, second.account, "the record on the key does not know which key")
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

        let display = EnrollmentService.credentialDisplayName(accountId: "vault")
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
        let display = EnrollmentService.credentialDisplayName(accountId: "vault")
        XCTAssertEqual(EnrollmentService.decodeUserFields(kind: .portable, name: name, displayName: display),
                       payload)
    }

    func testDisplayNameIsNeverEmpty() {
        for kind in AccountKind.allCases {
            let value = EnrollmentService.credentialDisplayName(accountId: "vault")
            XCTAssertFalse(value.isEmpty, "\(kind) enrolment would fail with FIDO_ERR_INVALID_LENGTH")
        }
    }

    /// Builds between the refactor and this fix put a prefixed payload in `displayName`.
    /// Those accounts exist on real keys and must keep opening.
    func testPrefixedInterimLayoutIsStillAccepted() {
        let payload = PortablePayload(external: Data(repeating: 0x5A, count: 32))!
        let decoded = EnrollmentService.decodeUserFields(kind: .portable,
                                                         name: "vault",
                                                         displayName: "fp-ext:v1:" + payload.base64)
        XCTAssertEqual(decoded, payload)
    }
}
