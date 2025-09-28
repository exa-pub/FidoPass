import XCTest
@testable import FidoPassCore
import TestSupport

final class FidoPassCoreFacadeTests: XCTestCase {
    func testFacadeForwardsCallsToDependencies() throws {
        let deviceRepository = MockDeviceRepository()
        let expectedDevice = FidoDevice(path: "/dev/mock",
                                        product: "Key",
                                        manufacturer: "Vendor",
                                        vendorId: 1,
                                        productId: 2)
        deviceRepository.devices = [expectedDevice]

        let enrollment = MockEnrollmentService()
        enrollment.enrollClosure = { accountId, rpId, _, _, _, _, _ in
            Account.fixture(id: accountId, rpId: rpId, userName: "user")
        }
        enrollment.enumerateClosure = { _, _, _ in
            [Account.fixture(id: "acct", rpId: "fidopass.local", userName: "user")]
        }

        let portable = MockPortableEnrollmentService()
        portable.enrollPortableClosure = { accountId, _, _, _, _ in
            (Account.fixture(id: accountId, rpId: "fidopass.portable", userName: ""), "generated")
        }
        portable.exportClosure = { _, _, _ in "exported" }

        let secret = MockSecretDerivationService()
        let passwordGenerator = MockPasswordGenerator()
        passwordGenerator.generateClosure = { _, _, _, _, _ in "secret-password" }

        let core = FidoPassCore(deviceRepository: deviceRepository,
                                enrollmentService: enrollment,
                                portableEnrollmentService: portable,
                                secretDerivationService: secret,
                                passwordGenerator: passwordGenerator)

        let devices = try core.listDevices(limit: 4)
        XCTAssertEqual(devices, [expectedDevice])
        XCTAssertEqual(deviceRepository.listedLimits, [4])

        let enrolled = try core.enroll(accountId: "acct",
                                       rpId: "fidopass.local",
                                       userName: "",
                                       requireUV: true,
                                       residentKey: true,
                                       devicePath: "/dev/mock",
                                       askPIN: nil)
        XCTAssertEqual(enrolled.id, "acct")
        XCTAssertEqual(enrollment.enrollCalls.count, 1)

        let (portableAccount, portableKey) = try core.enrollPortable(accountId: "pacct",
                                                                     requireUV: true,
                                                                     devicePath: "/dev/mock",
                                                                     askPIN: nil,
                                                                     importedKeyB64: nil)
        XCTAssertEqual(portableAccount.id, "pacct")
        XCTAssertEqual(portableKey, "generated")
        XCTAssertEqual(portable.enrollPortableCalls.count, 1)

        let password = try core.generatePassword(account: enrolled,
                                                 label: "label",
                                                 policy: nil,
                                                 requireUV: true,
                                                 pinProvider: nil)
        XCTAssertEqual(password, "secret-password")
        XCTAssertEqual(passwordGenerator.generateCalls.count, 1)

        let enumerated = try core.enumerateAccounts(devicePath: "/dev/mock", pin: "1234")
        XCTAssertEqual(enumerated.count, 1)
        XCTAssertEqual(enrollment.enumerateCalls.count, 1)

        let exported = try core.exportImportedKey(portableAccount,
                                                  requireUV: true,
                                                  pinProvider: nil)
        XCTAssertEqual(exported, "exported")
        XCTAssertEqual(portable.exportCalls.count, 1)

        try core.deleteAccount(enrolled, pin: "1234")
        XCTAssertEqual(enrollment.deleteCalls.count, 1)
    }
}
