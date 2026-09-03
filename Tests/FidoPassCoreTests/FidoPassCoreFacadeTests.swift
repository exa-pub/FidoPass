import XCTest
@testable import FidoPassCore
import TestSupport

final class FidoPassCoreFacadeTests: XCTestCase {
    func testFacadeForwardsCallsToDependencies() throws {
        let deviceLister = MockDeviceLister()
        let expectedDevice = FidoDevice(path: "/dev/mock",
                                        product: "Key",
                                        manufacturer: "Vendor",
                                        vendorId: 1,
                                        productId: 2)
        deviceLister.devices = [expectedDevice]

        let identity = AccountIdentity(hex: "0102030405060708090a0b0c0d0e0f10")!
        let enrollment = MockEnrollmentService()
        enrollment.enrollClosure = { accountId, kind, identity, devicePath, _, _ in
            AccountHandle.v2Fixture(id: accountId, kind: kind, identity: identity, devicePath: devicePath)
        }
        enrollment.enumerateClosure = { devicePath, _ in
            [AccountHandle.fixture(id: "acct", kind: .local, devicePath: devicePath)]
        }

        let generatedBackup = PortableBackup(masterKey: Data(repeating: 0x01, count: 32), identity: identity)!
        let exportedBackup = PortableBackup(masterKey: Data(repeating: 0x02, count: 32), identity: nil)!
        let portable = MockPortableEnrollmentService()
        portable.enrollPortableClosure = { accountId, identity, devicePath, _, _ in
            (AccountHandle.portableFixture(id: accountId, identity: identity, devicePath: devicePath), generatedBackup)
        }
        portable.exportClosure = { _, _ in exportedBackup }
        let migration = MockMigrationService()

        let secret = MockSecretDerivationService()
        let passwordGenerator = MockPasswordGenerator()
        passwordGenerator.generateClosure = { _, _, _, _ in "secret-password" }
        let messageKeys = RecordingMessageKeyService()
        let sealer = MessageSealer()

        let core = FidoPassCore(deviceLister: deviceLister,
                                enrollmentService: enrollment,
                                portableEnrollmentService: portable,
                                secretDerivationService: secret,
                                passwordGenerator: passwordGenerator,
                                messageKeyService: messageKeys,
                                messageSealer: sealer,
                                migrationService: migration)

        let devices = try core.listDevices()
        XCTAssertEqual(devices, [expectedDevice])
        XCTAssertEqual(deviceLister.listCalls, 1)

        let enrolled = try core.enroll(accountId: "acct",
                                       kind: .local,
                                       identity: identity,
                                       devicePath: "/dev/mock",
                                       askPIN: nil)
        XCTAssertEqual(enrolled.id, "acct")
        XCTAssertEqual(enrolled.devicePath, "/dev/mock")
        XCTAssertEqual(enrolled.account.identity, identity)
        XCTAssertEqual(enrollment.enrollCalls.count, 1)
        XCTAssertEqual(enrollment.enrollCalls.first?.namesakePolicy, .refuse, "the facade never allows a namesake")

        let (portableAccount, portableKey) = try core.enrollPortable(accountId: "pacct",
                                                                     identity: identity,
                                                                     devicePath: "/dev/mock",
                                                                     askPIN: nil,
                                                                     imported: nil)
        XCTAssertEqual(portableAccount.id, "pacct")
        XCTAssertEqual(portableKey, generatedBackup)
        XCTAssertEqual(portable.enrollPortableCalls.count, 1)

        let password = try core.generatePassword(enrolled, label: "label", pinProvider: nil)
        XCTAssertEqual(password, "secret-password")
        XCTAssertEqual(passwordGenerator.generateCalls.count, 1)
        XCTAssertEqual(passwordGenerator.generateCalls.first?.2, .v1,
                       "every account derives with the v1 parameters until the key can store them")

        let enumerated = try core.enumerateAccounts(devicePath: "/dev/mock", pin: "1234")
        XCTAssertEqual(enumerated.count, 1)
        XCTAssertEqual(enrollment.enumerateCalls.count, 1)

        let exported = try core.exportBackup(portableAccount, pinProvider: nil)
        XCTAssertEqual(exported, exportedBackup)
        XCTAssertEqual(portable.exportCalls.count, 1)

        let legacy = AccountHandle.portableFixture(id: "old", legacy: true)
        let migrated = try core.migrate(legacy, identity: identity)
        XCTAssertEqual(migrated.account.identity, identity)
        XCTAssertEqual(migrated.account.format, .v2)
        XCTAssertEqual(migration.migrateCalls.count, 1)
        _ = try core.finishMigration(old: legacy, copy: migrated)
        XCTAssertEqual(migration.finishCalls.count, 1)
        try core.discardMigrationCopy(migrated, pin: "1234")
        XCTAssertEqual(migration.discardCalls.count, 1)

        let messageKey = try core.deriveMessageKey(enrolled, nonce: MessageFixtures.nonce, pinProvider: nil)
        XCTAssertEqual(messageKey.url, try MessageFixtures.url())
        XCTAssertEqual(messageKeys.calls.map(\.0.id), ["acct"])
        XCTAssertEqual(messageKeys.calls.first?.1, MessageFixtures.nonce)
        XCTAssertTrue(core.messages is MessageSealer)

        try core.deleteAccount(enrolled, pin: "1234")
        XCTAssertEqual(enrollment.deleteCalls.count, 1)
    }
}

/// `MessageKey` is only constructible inside the core, so this mock lives here, with
/// `@testable` access, rather than in `TestSupport`.
private final class RecordingMessageKeyService: MessageKeyDeriving, @unchecked Sendable {
    private(set) var calls: [(AccountHandle, Data)] = []

    func deriveMessageKey(_ handle: AccountHandle, nonce: Data, pinProvider: (@Sendable () -> String?)?) throws -> MessageKey {
        calls.append((handle, nonce))
        return try MessageFixtures.key(nonce: nonce)
    }
}
