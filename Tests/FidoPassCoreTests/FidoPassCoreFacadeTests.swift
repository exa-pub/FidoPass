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

        let enrollment = MockEnrollmentService()
        enrollment.enrollClosure = { accountId, kind, devicePath, _ in
            AccountHandle.fixture(id: accountId, kind: kind, devicePath: devicePath)
        }
        enrollment.enumerateClosure = { _, devicePath, _ in
            [AccountHandle.fixture(id: "acct", kind: .local, devicePath: devicePath)]
        }

        let generatedBackup = PortableBackup(masterKey: Data(repeating: 0x01, count: 32),
                                             identity: AccountIdentity(hex: "0102030405060708090a0b0c"))!
        let exportedBackup = PortableBackup(masterKey: Data(repeating: 0x02, count: 32), identity: nil)!
        let portable = MockPortableEnrollmentService()
        portable.enrollPortableClosure = { accountId, devicePath, _, _ in
            (AccountHandle.portableFixture(id: accountId, devicePath: devicePath), generatedBackup)
        }
        portable.exportClosure = { _, _ in exportedBackup }

        let secret = MockSecretDerivationService()
        let passwordGenerator = MockPasswordGenerator()
        passwordGenerator.generateClosure = { _, _, _, _ in "secret-password" }

        let core = FidoPassCore(deviceLister: deviceLister,
                                enrollmentService: enrollment,
                                portableEnrollmentService: portable,
                                secretDerivationService: secret,
                                passwordGenerator: passwordGenerator)

        let devices = try core.listDevices()
        XCTAssertEqual(devices, [expectedDevice])
        XCTAssertEqual(deviceLister.listCalls, 1)

        let enrolled = try core.enroll(accountId: "acct",
                                       kind: .local,
                                       devicePath: "/dev/mock",
                                       askPIN: nil)
        XCTAssertEqual(enrolled.id, "acct")
        XCTAssertEqual(enrolled.devicePath, "/dev/mock")
        XCTAssertEqual(enrollment.enrollCalls.count, 1)

        let (portableAccount, portableKey) = try core.enrollPortable(accountId: "pacct",
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
        let identity = AccountIdentity(hex: "0c0b0a090807060504030201")!
        let migrated = try core.assignIdentity(legacy, identity: identity, pinProvider: nil)
        XCTAssertEqual(migrated.account.identity, identity)
        XCTAssertEqual(portable.assignIdentityCalls.count, 1)

        try core.deleteAccount(enrolled, pin: "1234")
        XCTAssertEqual(enrollment.deleteCalls.count, 1)
    }
}
