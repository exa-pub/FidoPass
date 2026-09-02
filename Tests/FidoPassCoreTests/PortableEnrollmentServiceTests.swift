import XCTest
@testable import FidoPassCore
import TestSupport

final class PortableEnrollmentServiceTests: XCTestCase {

    private let identity = AccountIdentity(hex: "a1a2a3a4a5a6a7a8a9aaabac")!

    private func makeService(fixed: Data,
                             enrollment: MockEnrollmentService = MockEnrollmentService()) -> (PortableEnrollmentService, MockEnrollmentService, MockSecretDerivationService) {
        let secret = MockSecretDerivationService()
        secret.deriveFixedClosure = { _, _ in fixed }
        enrollment.enrollClosure = { accountId, kind, devicePath, _ in
            AccountHandle.fixture(id: accountId,
                                  kind: kind,
                                  credentialId: Data("cred".utf8),
                                  devicePath: devicePath)
        }
        return (PortableEnrollmentService(enrollmentService: enrollment, secretDerivationService: secret),
                enrollment,
                secret)
    }

    // MARK: - Enrolment

    func testEnrollPortableGeneratesKeyAndIdentityWhenNothingIsImported() throws {
        let fixed = Data(repeating: 0xAB, count: 32)
        let (service, enrollment, secret) = makeService(fixed: fixed)

        let (account, generated) = try service.enrollPortable(accountId: "acct",
                                                               devicePath: "/dev/key",
                                                               askPIN: nil,
                                                               imported: nil,
                                                               onStep: nil)

        XCTAssertEqual(account.kind, AccountKind.portable)
        XCTAssertEqual(enrollment.updateCalls.count, 1)
        XCTAssertEqual(secret.deriveFixedCalls.count, 1)

        let backup = try XCTUnwrap(generated, "fresh material has to be handed back to be written down")
        XCTAssertFalse(backup.isLegacy)
        let payload = try XCTUnwrap(account.account.portable)
        XCTAssertEqual(payload.identity, backup.identity, "the backup carries the identity the key was given")
        XCTAssertFalse(payload.needsMigration, "a freshly written payload is never in the old layout")
        XCTAssertEqual(payload.base64.count, 60)
        XCTAssertEqual(Data(zip(backup.masterKey, fixed).map { $0 ^ $1 }), payload.external)
    }

    func testEnrollPortableKeepsTheImportedKeyAndIdentity() throws {
        let fixed = Data(repeating: 0x11, count: 32)
        let (service, _, _) = makeService(fixed: fixed)
        let imported = PortableBackup(masterKey: Data(repeating: 0x22, count: 32), identity: identity)!

        let (account, generated) = try service.enrollPortable(accountId: "acct",
                                                               devicePath: "/dev/mock",
                                                               askPIN: nil,
                                                               imported: imported,
                                                               onStep: nil)

        XCTAssertNil(generated, "an import has its backup already")
        let payload = try XCTUnwrap(account.account.portable)
        XCTAssertEqual(Data(zip(imported.masterKey, fixed).map { $0 ^ $1 }), payload.external)
        XCTAssertEqual(payload.identity, identity, "the second key shows the same identity as the first")
    }

    /// A backup printed before identities existed has none. The panel asks for one before
    /// importing; if one still reaches the service, the account gets a random one rather
    /// than the layout that would need migrating the moment it was created.
    func testEnrollPortableGivesALegacyImportAnIdentity() throws {
        let (service, _, _) = makeService(fixed: Data(repeating: 0x11, count: 32))
        let legacy = PortableBackup(masterKey: Data(repeating: 0x22, count: 32), identity: nil)!

        let (account, generated) = try service.enrollPortable(accountId: "acct",
                                                               devicePath: "/dev/mock",
                                                               askPIN: nil,
                                                               imported: legacy,
                                                               onStep: nil)
        XCTAssertNil(generated)
        XCTAssertNotNil(account.account.portable?.identity)
        XCTAssertFalse(account.account.needsMigration)
    }

    func testEnrollPortableReportsEveryStep() throws {
        let (service, _, _) = makeService(fixed: Data(repeating: 0x00, count: 32))
        nonisolated(unsafe) var steps: [PortableEnrollmentStep] = []
        _ = try service.enrollPortable(accountId: "acct",
                                       devicePath: "/dev/mock",
                                       askPIN: nil,
                                       imported: nil,
                                       onStep: { steps.append($0) })
        XCTAssertEqual(steps, [.creatingCredential, .derivingBackupKey, .savingPayload])
    }

    // MARK: - Export

    func testExportBackupCarriesTheMasterKeyAndTheIdentity() throws {
        let fixed = Data(repeating: 0xA5, count: 32)
        let (service, _, secret) = makeService(fixed: fixed)
        let masterKey = Data((0..<32).map { UInt8(truncatingIfNeeded: $0) })
        let external = Data(zip(masterKey, fixed).map { $0 ^ $1 })
        let account = AccountHandle.fixture(kind: .portable,
                                            portable: PortablePayload(external: external, identity: identity))

        let backup = try service.exportBackup(account, pinProvider: nil)
        XCTAssertEqual(backup.masterKey, masterKey)
        XCTAssertEqual(backup.identity, identity)
        XCTAssertFalse(backup.isLegacy)
        XCTAssertEqual(secret.deriveFixedCalls.count, 1, "one touch")
    }

    /// An account from before identities exports what it always did — the same 32 bytes,
    /// without an identity. Export does not wait for migration.
    func testExportBackupOfALegacyAccountIsTheLegacyBackup() throws {
        let fixed = Data(repeating: 0xA5, count: 32)
        let (service, _, _) = makeService(fixed: fixed)
        let masterKey = Data((0..<32).map { UInt8(truncatingIfNeeded: 0xF0 &- $0) })
        let external = Data(zip(masterKey, fixed).map { $0 ^ $1 })
        let legacy = AccountHandle.fixture(kind: .portable, portable: PortablePayload(external: external))
        XCTAssertTrue(legacy.account.needsMigration)

        let backup = try service.exportBackup(legacy, pinProvider: nil)
        XCTAssertTrue(backup.isLegacy)
        XCTAssertEqual(backup.masterKey, masterKey)
        XCTAssertEqual(backup.base64, masterKey.base64EncodedString(),
                       "byte for byte what earlier versions printed as the backup key")
        XCTAssertEqual(backup.base64.count, 44)
    }

    func testExportBackupNeedsAPortableAccountWithMaterial() {
        let (service, _, _) = makeService(fixed: Data(repeating: 0x00, count: 32))
        XCTAssertThrowsError(try service.exportBackup(AccountHandle.fixture(kind: .local), pinProvider: nil))
        XCTAssertThrowsError(try service.exportBackup(AccountHandle.fixture(kind: .portable, portable: nil), pinProvider: nil))
    }

    // MARK: - Migration

    func testAssignIdentityRewritesTheNameAndNothingElse() throws {
        let (service, enrollment, secret) = makeService(fixed: Data(repeating: 0x00, count: 32))
        let external = Data(repeating: 0x5A, count: 32)
        let legacy = AccountHandle.fixture(id: "vault", kind: .portable, portable: PortablePayload(external: external))

        let migrated = try service.assignIdentity(legacy, identity: identity, pinProvider: nil)

        XCTAssertEqual(enrollment.updateCalls.count, 1, "one credential-management write")
        XCTAssertEqual(enrollment.updateCalls.first?.account.portable?.identity, identity,
                       "the payload handed to the key carries the identity")
        XCTAssertEqual(secret.deriveFixedCalls.count, 0, "no touch: the key material is not recomputed")
        XCTAssertEqual(migrated.account.portable?.external, external, "the material is untouched")
        XCTAssertEqual(migrated.account.identity, identity)
        XCTAssertFalse(migrated.account.needsMigration)
        XCTAssertEqual(migrated.devicePath, legacy.devicePath)
        XCTAssertEqual(migrated.id, "vault")
    }

    /// Identities are meant to be stable. Re-assigning one is not migration and is refused.
    func testAssignIdentityRefusesAnAccountThatAlreadyHasOne() throws {
        let (service, enrollment, _) = makeService(fixed: Data(repeating: 0x00, count: 32))
        let current = AccountHandle.portableFixture(id: "vault")
        XCTAssertThrowsError(try service.assignIdentity(current, identity: identity, pinProvider: nil))
        XCTAssertEqual(enrollment.updateCalls.count, 0)
    }

    func testAssignIdentityNeedsAPortableAccountWithMaterial() {
        let (service, enrollment, _) = makeService(fixed: Data(repeating: 0x00, count: 32))
        XCTAssertThrowsError(try service.assignIdentity(AccountHandle.fixture(kind: .local),
                                                        identity: identity,
                                                        pinProvider: nil))
        XCTAssertThrowsError(try service.assignIdentity(AccountHandle.fixture(kind: .portable, portable: nil),
                                                        identity: identity,
                                                        pinProvider: nil))
        XCTAssertEqual(enrollment.updateCalls.count, 0)
    }

    /// The write itself can be refused by the key; the caller must see that rather than a
    /// handle claiming to be migrated.
    func testAssignIdentityPropagatesARefusedWrite() {
        let enrollment = MockEnrollmentService()
        enrollment.updateClosure = { _, _ in throw TestError.generic("refused") }
        let (service, _, _) = makeService(fixed: Data(repeating: 0x00, count: 32), enrollment: enrollment)
        let legacy = AccountHandle.portableFixture(id: "vault", legacy: true)
        XCTAssertThrowsError(try service.assignIdentity(legacy, identity: identity, pinProvider: nil)) { error in
            XCTAssertEqual(error as? TestError, .generic("refused"))
        }
    }
}
