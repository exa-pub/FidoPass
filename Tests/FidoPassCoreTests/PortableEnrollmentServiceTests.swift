import XCTest
@testable import FidoPassCore
import TestSupport

final class PortableEnrollmentServiceTests: XCTestCase {

    private let identity = AccountIdentity(hex: "a1a2a3a4a5a6a7a8a9aaabacadaeaf00")!

    private func makeService(fixed: Data,
                             enrollment: MockEnrollmentService = MockEnrollmentService()) -> (PortableEnrollmentService, MockEnrollmentService, MockSecretDerivationService) {
        let secret = MockSecretDerivationService()
        secret.deriveFixedClosure = { _, _ in fixed }
        return (PortableEnrollmentService(enrollmentService: enrollment, secretDerivationService: secret),
                enrollment,
                secret)
    }

    // MARK: - Enrolment

    func testEnrollPortableGeneratesKeyWhenNothingIsImported() throws {
        let fixed = Data(repeating: 0xAB, count: 32)
        let (service, enrollment, secret) = makeService(fixed: fixed)

        let (account, generated) = try service.enrollPortable(accountId: "acct",
                                                               identity: identity,
                                                               devicePath: "/dev/key",
                                                               askPIN: nil,
                                                               imported: nil,
                                                               onStep: nil)

        XCTAssertEqual(account.kind, .portable)
        XCTAssertEqual(account.account.format, .v2)
        XCTAssertEqual(account.account.identity, identity, "the identity the form chose is the one on the key")
        XCTAssertEqual(account.account.integrity, .ok)
        XCTAssertEqual(enrollment.enrollCalls.map(\.identity), [identity])
        XCTAssertEqual(enrollment.enrollCalls.first?.namesakePolicy, .refuse)
        XCTAssertEqual(enrollment.writeRecordCalls.count, 1, "the record is written once, after the mask exists")
        XCTAssertEqual(secret.deriveFixedCalls.count, 1)

        let backup = try XCTUnwrap(generated, "fresh material has to be handed back to be written down")
        XCTAssertFalse(backup.isLegacy)
        XCTAssertEqual(backup.identity, identity)
        XCTAssertEqual(backup.base64.count, 64)
        let mask = try XCTUnwrap(account.account.mask)
        XCTAssertEqual(Data(zip(backup.masterKey, fixed).map { $0 ^ $1 }), mask)
        XCTAssertEqual(enrollment.writeRecordCalls.first?.account.mask, mask, "what went to the key is the mask")
    }

    func testEnrollPortableKeepsTheImportedKey() throws {
        let fixed = Data(repeating: 0x11, count: 32)
        let (service, _, _) = makeService(fixed: fixed)
        let imported = PortableBackup(masterKey: Data(repeating: 0x22, count: 32), identity: identity)!

        let (account, generated) = try service.enrollPortable(accountId: "acct",
                                                               identity: identity,
                                                               devicePath: "/dev/mock",
                                                               askPIN: nil,
                                                               imported: imported,
                                                               onStep: nil)

        XCTAssertNil(generated, "an import has its backup already")
        XCTAssertEqual(Data(zip(imported.masterKey, fixed).map { $0 ^ $1 }), account.account.mask)
        XCTAssertEqual(account.account.identity, identity, "the second key shows the same identity as the first")
    }

    func testEnrollPortableReportsEveryStep() throws {
        let (service, _, _) = makeService(fixed: Data(repeating: 0x00, count: 32))
        nonisolated(unsafe) var steps: [PortableEnrollmentStep] = []
        _ = try service.enrollPortable(accountId: "acct",
                                       identity: identity,
                                       devicePath: "/dev/mock",
                                       askPIN: nil,
                                       imported: nil,
                                       onStep: { steps.append($0) })
        XCTAssertEqual(steps, [.creatingCredential, .derivingBackupKey, .savingRecord])
    }

    /// A credential without a record is not an account. If the record cannot be written, the
    /// credential goes back off the key rather than sitting in a slot as "incomplete".
    func testAFailedRecordWriteTakesTheCredentialBack() {
        let enrollment = MockEnrollmentService()
        enrollment.writeRecordClosure = { _, _ in throw TestError.generic("store full") }
        let (service, _, _) = makeService(fixed: Data(repeating: 0x00, count: 32), enrollment: enrollment)

        XCTAssertThrowsError(try service.enrollPortable(accountId: "acct",
                                                        identity: identity,
                                                        devicePath: "/dev/mock",
                                                        askPIN: { "1234" },
                                                        imported: nil,
                                                        onStep: nil)) { error in
            XCTAssertEqual(error as? TestError, .generic("store full"))
        }
        XCTAssertEqual(enrollment.deleteCalls.count, 1)
        XCTAssertEqual(enrollment.deleteCalls.first?.0.id, "acct")
        XCTAssertEqual(enrollment.deleteCalls.first?.1, "1234")
    }

    func testAFailedFixedComponentTakesTheCredentialBack() {
        let enrollment = MockEnrollmentService()
        let secret = MockSecretDerivationService()
        secret.deriveFixedClosure = { _, _ in throw TestError.generic("no touch") }
        let service = PortableEnrollmentService(enrollmentService: enrollment, secretDerivationService: secret)

        XCTAssertThrowsError(try service.enrollPortable(accountId: "acct",
                                                        identity: identity,
                                                        devicePath: "/dev/mock",
                                                        askPIN: nil,
                                                        imported: nil,
                                                        onStep: nil))
        XCTAssertEqual(enrollment.deleteCalls.count, 1)
        XCTAssertTrue(enrollment.writeRecordCalls.isEmpty)
    }

    // MARK: - Export

    func testExportBackupCarriesTheMasterKeyAndTheIdentity() throws {
        let fixed = Data(repeating: 0xA5, count: 32)
        let (service, _, secret) = makeService(fixed: fixed)
        let masterKey = Data((0..<32).map { UInt8(truncatingIfNeeded: $0) })
        let mask = Data(zip(masterKey, fixed).map { $0 ^ $1 })
        let account = AccountHandle.v2Fixture(kind: .portable, identity: identity, mask: mask)

        let backup = try service.exportBackup(account, pinProvider: nil)
        XCTAssertEqual(backup.masterKey, masterKey)
        XCTAssertEqual(backup.identity, identity)
        XCTAssertFalse(backup.isLegacy)
        XCTAssertEqual(secret.deriveFixedCalls.count, 1, "one touch")
    }

    /// A v1 account exports what it always did — the same 32 bytes, without an identity.
    /// Export does not wait for migration.
    func testExportBackupOfAV1AccountIsTheLegacyBackup() throws {
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
        let (service, _, secret) = makeService(fixed: Data(repeating: 0x00, count: 32))
        XCTAssertThrowsError(try service.exportBackup(AccountHandle.fixture(kind: .local), pinProvider: nil))
        XCTAssertThrowsError(try service.exportBackup(AccountHandle.fixture(kind: .portable, portable: nil), pinProvider: nil))
        XCTAssertThrowsError(try service.exportBackup(AccountHandle.v2Fixture(kind: .portable, integrity: .recordMissing), pinProvider: nil))
        XCTAssertTrue(secret.deriveFixedCalls.isEmpty, "no touch is spent on an account that cannot export")
    }
}
