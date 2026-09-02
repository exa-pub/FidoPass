import XCTest
@testable import FidoPassCore
import TestSupport

final class PortableEnrollmentServiceTests: XCTestCase {
    func testEnrollPortableGeneratesKeyWhenMissing() throws {
        let enrollment = MockEnrollmentService()
        let fixed = Data(repeating: 0xAB, count: 32)
        let secret = MockSecretDerivationService()
        secret.deriveFixedClosure = { _, _ in fixed }
        enrollment.enrollClosure = { accountId, kind, devicePath, _ in
            AccountHandle.fixture(id: accountId,
                                  kind: kind,
                                  credentialId: Data("cred".utf8),
                                  devicePath: devicePath)
        }
        let service = PortableEnrollmentService(enrollmentService: enrollment,
                                                secretDerivationService: secret)

        let (account, generated) = try service.enrollPortable(accountId: "acct",
                                                               devicePath: "/dev/key",
                                                               askPIN: nil,
                                                               importedKeyB64: nil,
                                                               onStep: nil)

        XCTAssertEqual(account.kind, AccountKind.portable)
        XCTAssertNotNil(generated)
        XCTAssertEqual(enrollment.updateCalls.count, 1)
        XCTAssertEqual(secret.deriveFixedCalls.count, 1)

        let external = try XCTUnwrap(account.account.portable?.external)
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
        secret.deriveFixedClosure = { _, _ in fixed }
        enrollment.enrollClosure = { accountId, kind, devicePath, _ in
            AccountHandle.fixture(id: accountId, kind: kind, devicePath: devicePath)
        }
        let service = PortableEnrollmentService(enrollmentService: enrollment,
                                                secretDerivationService: secret)
        let imported = Data(repeating: 0x22, count: 32).base64EncodedString()

        let (account, generated) = try service.enrollPortable(accountId: "acct",
                                                               devicePath: "/dev/mock",
                                                               askPIN: nil,
                                                               importedKeyB64: imported,
                                                               onStep: nil)

        XCTAssertNil(generated)
        let external = try XCTUnwrap(account.account.portable?.external)
        let importedData = try XCTUnwrap(Data(base64Encoded: imported))
        let recomposed = Data(zip(importedData, fixed).map { $0 ^ $1 })
        XCTAssertEqual(recomposed, external)
    }

    func testEnrollPortableValidatesImportedKeyLength() throws {
        let enrollment = MockEnrollmentService()
        enrollment.enrollClosure = { accountId, kind, devicePath, _ in
            AccountHandle.fixture(id: accountId, kind: kind, devicePath: devicePath)
        }
        let secret = MockSecretDerivationService()
        secret.deriveFixedClosure = { _, _ in Data(repeating: 0x00, count: 32) }
        let service = PortableEnrollmentService(enrollmentService: enrollment,
                                                secretDerivationService: secret)
        XCTAssertThrowsError(try service.enrollPortable(accountId: "acct",
                                                         devicePath: "/dev/mock",
                                                         askPIN: nil,
                                                         importedKeyB64: "short",
                                                               onStep: nil))
    }

    func testExportImportedKeyReconstructsOriginal() throws {
        let secret = MockSecretDerivationService()
        let fixed = Data(repeating: 0xA5, count: 32)
        secret.deriveFixedClosure = { _, _ in fixed }
        let service = PortableEnrollmentService(enrollmentService: MockEnrollmentService(),
                                                secretDerivationService: secret)

        let imported = Data((0..<32).map { UInt8(truncatingIfNeeded: $0) })
        let external = Data(zip(imported, fixed).map { $0 ^ $1 })
        let account = AccountHandle.fixture(kind: .portable,
                                      portable: PortablePayload(external: external))

        let reconstructed = try service.exportImportedKey(account,
                                                           pinProvider: nil)
        XCTAssertEqual(Data(base64Encoded: reconstructed), imported)
    }
}
