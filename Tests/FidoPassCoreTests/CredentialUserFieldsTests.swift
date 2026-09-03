import XCTest
@testable import FidoPassCore
import TestSupport

/// What the key holds for an account, in each layout, and how it reads back.
///
/// v1 credentials are on users' keys right now and losing a portable one's payload would
/// make the passwords derived from it unreproducible, so both v1 layouts of it must keep
/// reading. v2 credentials keep a name in `user.name` and the rest in their record.
final class CredentialUserFieldsTests: XCTestCase {

    private let payload = Data(repeating: 0xA7, count: PortablePayload.externalByteCount)

    // MARK: - v1, read only

    /// The released layout: raw base64 payload in `name`, account id in `displayName`.
    func testV1PortableLayoutIsRead() {
        let decoded = EnrollmentService.decodeUserFields(kind: .portable,
                                                         name: payload.base64EncodedString(),
                                                         displayName: "acct")
        XCTAssertEqual(decoded?.external, payload)
    }

    /// A few intermediate builds put the payload in `displayName` behind a prefix. Those
    /// accounts are on real keys.
    func testV1PrefixedDisplayNameLayoutIsRead() {
        let decoded = EnrollmentService.decodeUserFields(kind: .portable,
                                                         name: "acct",
                                                         displayName: "fp-ext:v1:" + payload.base64EncodedString())
        XCTAssertEqual(decoded?.external, payload)
    }

    func testLocalAccountsCarryNoPayload() {
        XCTAssertNil(EnrollmentService.decodeUserFields(kind: .local, name: "acct", displayName: "Work vault"))
        XCTAssertNil(EnrollmentService.decodeUserFields(kind: .local,
                                                        name: payload.base64EncodedString(),
                                                        displayName: payload.base64EncodedString()),
                     "a local name that merely looks like base64 is not key material")
    }

    func testPortableWithUnreadablePayloadDoesNotCrash() {
        XCTAssertNil(EnrollmentService.decodeUserFields(kind: .portable, name: "not-base64!", displayName: "not-base64!"))
    }

    /// Exactly 32 bytes. The 44-byte layout an unreleased build wrote — material followed by
    /// a 12-byte identity — is not read: nothing shipped with it.
    func testPayloadLengthIsEnforced() {
        XCTAssertNil(PortablePayload(external: Data(repeating: 0x01, count: 31)))
        XCTAssertNil(PortablePayload(external: Data(repeating: 0x01, count: 33)))
        XCTAssertNotNil(PortablePayload(external: Data(repeating: 0x01, count: 32)))
        XCTAssertNil(PortablePayload(base64: "definitely not base64 %%%"))
        for count in [16, 33, 43, 44, 45, 48] {
            XCTAssertNil(PortablePayload(base64: Data(repeating: 0x01, count: count).base64EncodedString()),
                         "\(count) bytes is not a payload")
        }
    }

    // MARK: - The account model

    /// The identity is derived for a local v1 account and absent for a portable one; a v2
    /// account of either kind carries the one it was created with.
    func testAccountIdentityPerFormatAndKind() {
        let local = Account.fixture(id: "disk", kind: .local, credentialId: Data("cred".utf8))
        XCTAssertEqual(local.format, .v1)
        XCTAssertEqual(local.identity, AccountIdentity.derived(fromCredentialId: Data("cred".utf8)))
        XCTAssertFalse(local.needsMigration, "a local account never migrates")
        XCTAssertTrue(local.canDerive)

        let legacy = Account.fixture(kind: .portable, portable: PortablePayload(external: payload))
        XCTAssertNil(legacy.identity)
        XCTAssertEqual(legacy.mask, payload)
        XCTAssertTrue(legacy.needsMigration)
        XCTAssertTrue(legacy.canDerive, "it derives what it always did until it is migrated")

        let unreadable = Account.fixture(kind: .portable, portable: nil)
        XCTAssertNil(unreadable.identity)
        XCTAssertNil(unreadable.mask)
        XCTAssertEqual(unreadable.integrity, .recordCorrupt)
        XCTAssertFalse(unreadable.needsMigration, "missing material is a different failure from a missing identity")
        XCTAssertFalse(unreadable.canDerive)

        let identity = AccountIdentity(hex: "0102030405060708090a0b0c0d0e0f10")!
        let current = Account.v2Fixture(id: "vault", kind: .portable, identity: identity)
        XCTAssertEqual(current.format, .v2)
        XCTAssertEqual(current.identity, identity)
        XCTAssertNotNil(current.mask)
        XCTAssertFalse(current.needsMigration)
        XCTAssertEqual(current.rpId, "fidopass.org")

        let currentLocal = Account.v2Fixture(id: "disk", kind: .local, identity: identity)
        XCTAssertEqual(currentLocal.identity, identity)
        XCTAssertNil(currentLocal.mask)
        XCTAssertEqual(currentLocal.rpId, "fidopass.org")
    }

    /// A v2 credential without a usable record is not an account: nothing derives from it.
    func testAnIncompleteAccountCannotDerive() {
        let missing = Account.v2Fixture(id: "half", kind: .local, integrity: .recordMissing)
        XCTAssertFalse(missing.canDerive)
        XCTAssertFalse(missing.needsMigration)
        XCTAssertNotNil(missing.integrity.problem)
        XCTAssertNil(AccountIntegrity.ok.problem)
    }

    /// The name is a name: 1–64 bytes of UTF-8, as CTAP guarantees an authenticator keeps.
    func testUserNameLimits() throws {
        XCTAssertEqual(try EnrollmentService.encodeUserName("vault"), "vault")
        XCTAssertEqual(try EnrollmentService.encodeUserName("хранилище"), "хранилище")
        XCTAssertEqual(try EnrollmentService.encodeUserName(String(repeating: "a", count: 64)).utf8.count, 64)
        XCTAssertThrowsError(try EnrollmentService.encodeUserName(""))
        XCTAssertThrowsError(try EnrollmentService.encodeUserName(String(repeating: "a", count: 65)))
        XCTAssertThrowsError(try EnrollmentService.encodeUserName(String(repeating: "я", count: 33)), "66 bytes")
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
