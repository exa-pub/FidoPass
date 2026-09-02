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

        let portable = MockPortableEnrollmentService()
        portable.enrollPortableClosure = { accountId, devicePath, _, _ in
            (AccountHandle.fixture(id: accountId, kind: .portable, devicePath: devicePath), "generated")
        }
        portable.exportClosure = { _, _ in "exported" }

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
                                                                     importedKeyB64: nil)
        XCTAssertEqual(portableAccount.id, "pacct")
        XCTAssertEqual(portableKey, "generated")
        XCTAssertEqual(portable.enrollPortableCalls.count, 1)

        let password = try core.generatePassword(enrolled, label: "label", pinProvider: nil)
        XCTAssertEqual(password, "secret-password")
        XCTAssertEqual(passwordGenerator.generateCalls.count, 1)
        XCTAssertEqual(passwordGenerator.generateCalls.first?.2, .v1,
                       "every account derives with the v1 parameters until the key can store them")

        let enumerated = try core.enumerateAccounts(devicePath: "/dev/mock", pin: "1234")
        XCTAssertEqual(enumerated.count, 1)
        XCTAssertEqual(enrollment.enumerateCalls.count, 1)

        let exported = try core.exportImportedKey(portableAccount, pinProvider: nil)
        XCTAssertEqual(exported, "exported")
        XCTAssertEqual(portable.exportCalls.count, 1)

        try core.deleteAccount(enrolled, pin: "1234")
        XCTAssertEqual(enrollment.deleteCalls.count, 1)
    }
}
