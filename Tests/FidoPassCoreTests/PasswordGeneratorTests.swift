import XCTest
import CryptoKit
@testable import FidoPassCore
import TestSupport

final class PasswordGeneratorTests: XCTestCase {
    func testGeneratePasswordUsesDerivedSecretForResidentAccount() throws {
        let secretService = MockSecretDerivationService()
        let secret = Data(repeating: 0xAA, count: 32)
        secretService.deriveSecretClosure = { account, label, requireUV, _ in
            XCTAssertEqual(account.id, "resident")
            XCTAssertEqual(label, "label")
            XCTAssertTrue(requireUV)
            return secret
        }
        let generator = PasswordGenerator(secretDerivationService: secretService)
        var account = Account.fixture(id: "resident")
        account.policy = PasswordPolicy(length: 16, useLower: true, useUpper: false, useDigits: false, useSymbols: false)
        let password = try generator.generatePassword(account: account,
                                                       label: "label",
                                                       policy: PasswordPolicy(length: 8, useLower: true, useUpper: true, useDigits: true, useSymbols: false),
                                                       requireUV: true,
                                                       pinProvider: nil)
        XCTAssertEqual(password.count, 8)
        XCTAssertEqual(secretService.deriveSecretCalls.count, 1)
        XCTAssertEqual(secretService.deriveFixedCalls.count, 0)
    }

    func testGeneratePasswordPortableFlowUsesImportedKey() throws {
        let secretService = MockSecretDerivationService()
        let fixed = Data(repeating: 0x0F, count: 32)
        secretService.deriveFixedClosure = { _, _, _ in fixed }
        let generator = PasswordGenerator(secretDerivationService: secretService)

        let imported = Data(repeating: 0xF0, count: 32)
        let external = Data(zip(imported, fixed).map { $0 ^ $1 })
        let account = Account.fixture(id: "portable",
                                      rpId: "fidopass.portable",
                                      userName: external.base64EncodedString())

        let password = try generator.generatePassword(account: account,
                                                       label: "example",
                                                       policy: nil,
                                                       requireUV: true,
                                                       pinProvider: nil)

        let salt = SaltFactory.portableLabelSalt("example")
        let importedKey = SymmetricKey(data: imported)
        let mac = HMAC<SHA256>.authenticationCode(for: salt, using: importedKey)
        let secret = Data(mac)
        let hkdfKey = SymmetricKey(data: secret)
        let info = Data("fidopass|pw|v\(account.policy.version)".utf8)
        let saltData = Data("pw-map".utf8)
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: hkdfKey,
                                             salt: saltData,
                                             info: info,
                                             outputByteCount: max(64, account.policy.length * 3))
        let material = Data(derived.withUnsafeBytes { Data($0) })
        let expected = PasswordEngine.mapToPassword(material, policy: account.policy)

        XCTAssertEqual(password, expected)
        XCTAssertEqual(secretService.deriveSecretCalls.count, 0)
        XCTAssertEqual(secretService.deriveFixedCalls.count, 1)
    }

    func testGeneratePasswordPropagatesErrors() {
        let secretService = MockSecretDerivationService()
        secretService.deriveSecretClosure = { _, _, _, _ in
            throw TestError.generic("failed")
        }
        let generator = PasswordGenerator(secretDerivationService: secretService)
        let account = Account.fixture()
        XCTAssertThrowsError(try generator.generatePassword(account: account,
                                                             label: "label",
                                                             policy: nil,
                                                             requireUV: true,
                                                             pinProvider: nil)) { error in
            XCTAssertEqual(error as? TestError, .generic("failed"))
        }
    }

    func testGeneratePasswordFailsForInvalidPortablePayload() {
        let secretService = MockSecretDerivationService()
        secretService.deriveFixedClosure = { _, _, _ in Data(repeating: 0x00, count: 32) }
        let generator = PasswordGenerator(secretDerivationService: secretService)
        let account = Account.fixture(rpId: "fidopass.portable", userName: "invalid-b64")
        XCTAssertThrowsError(try generator.generatePassword(account: account,
                                                             label: "label",
                                                             policy: nil,
                                                             requireUV: true,
                                                             pinProvider: nil))
    }
}
