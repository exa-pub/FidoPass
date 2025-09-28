import XCTest
@testable import FidoPassCore
import TestSupport

final class PortableEnrollmentServiceTests: XCTestCase {
    func testEnrollPortableGeneratesKeyWhenMissing() throws {
        let enrollment = MockEnrollmentService()
        let fixed = Data(repeating: 0xAB, count: 32)
        let secret = MockSecretDerivationService()
        secret.deriveFixedClosure = { _, _, _ in fixed }
        enrollment.enrollClosure = { accountId, rpId, _, _, _, devicePath, _ in
            Account.fixture(id: accountId,
                            rpId: rpId,
                            userName: "",
                            credentialId: Data("cred".utf8),
                            devicePath: devicePath)
        }
        let service = PortableEnrollmentService(enrollmentService: enrollment,
                                                secretDerivationService: secret)

        let (account, generated) = try service.enrollPortable(accountId: "acct",
                                                               requireUV: true,
                                                               devicePath: "/dev/key",
                                                               askPIN: nil,
                                                               importedKeyB64: nil)

        XCTAssertEqual(account.rpId, "fidopass.portable")
        XCTAssertNotNil(generated)
        XCTAssertEqual(enrollment.updateCalls.count, 1)
        XCTAssertEqual(secret.deriveFixedCalls.count, 1)

        let external = try XCTUnwrap(Data(base64Encoded: account.userName))
        let imported = try XCTUnwrap(Data(base64Encoded: generated!))
        XCTAssertEqual(external.count, 32)
        XCTAssertEqual(imported.count, 32)

        let recomposed = Data(zip(imported, fixed).map { $0 ^ $1 })
        XCTAssertEqual(recomposed, external)
    }

    func testEnrollPortableUsesProvidedKey() throws {
        let enrollment = MockEnrollmentService()
        let fixed = Data(repeating: 0x11, count: 32)
        let secret = MockSecretDerivationService()
        secret.deriveFixedClosure = { _, _, _ in fixed }
        enrollment.enrollClosure = { accountId, rpId, _, _, _, _, _ in
            Account.fixture(id: accountId, rpId: rpId, userName: "")
        }
        let service = PortableEnrollmentService(enrollmentService: enrollment,
                                                secretDerivationService: secret)
        let imported = Data(repeating: 0x22, count: 32).base64EncodedString()

        let (account, generated) = try service.enrollPortable(accountId: "acct",
                                                               requireUV: false,
                                                               devicePath: nil,
                                                               askPIN: nil,
                                                               importedKeyB64: imported)

        XCTAssertNil(generated)
        let external = try XCTUnwrap(Data(base64Encoded: account.userName))
        let importedData = try XCTUnwrap(Data(base64Encoded: imported))
        let recomposed = Data(zip(importedData, fixed).map { $0 ^ $1 })
        XCTAssertEqual(recomposed, external)
    }

    func testEnrollPortableValidatesImportedKeyLength() throws {
        let enrollment = MockEnrollmentService()
        enrollment.enrollClosure = { accountId, rpId, _, _, _, _, _ in
            Account.fixture(id: accountId, rpId: rpId, userName: "")
        }
        let secret = MockSecretDerivationService()
        secret.deriveFixedClosure = { _, _, _ in Data(repeating: 0x00, count: 32) }
        let service = PortableEnrollmentService(enrollmentService: enrollment,
                                                secretDerivationService: secret)
        XCTAssertThrowsError(try service.enrollPortable(accountId: "acct",
                                                         requireUV: true,
                                                         devicePath: nil,
                                                         askPIN: nil,
                                                         importedKeyB64: "short"))
    }

    func testExportImportedKeyReconstructsOriginal() throws {
        let secret = MockSecretDerivationService()
        let fixed = Data(repeating: 0xA5, count: 32)
        secret.deriveFixedClosure = { _, _, _ in fixed }
        let service = PortableEnrollmentService(enrollmentService: MockEnrollmentService(),
                                                secretDerivationService: secret)

        let imported = Data((0..<32).map { UInt8($0) })
        let external = Data(zip(imported, fixed).map { $0 ^ $1 })
        let account = Account.fixture(rpId: "fidopass.portable",
                                      userName: external.base64EncodedString())

        let reconstructed = try service.exportImportedKey(account,
                                                           requireUV: true,
                                                           pinProvider: nil)
        XCTAssertEqual(Data(base64Encoded: reconstructed), imported)
    }
}
