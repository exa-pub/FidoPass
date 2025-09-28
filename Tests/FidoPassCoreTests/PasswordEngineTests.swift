import XCTest
@testable import FidoPassCore

final class PasswordEngineTests: XCTestCase {
    func testAlphabetRespectsCharacterFlags() {
        let policy = PasswordPolicy(length: 10,
                                     useLower: false,
                                     useUpper: true,
                                     useDigits: false,
                                     useSymbols: true,
                                     avoidAmbiguous: true,
                                     version: 1)
        let alphabet = PasswordEngine.alphabet(policy: policy)
        XCTAssertFalse(alphabet.contains(where: { CharacterSet.lowercaseLetters.contains($0.unicodeScalars.first!) }))
        XCTAssertTrue(alphabet.contains("A"))
        XCTAssertTrue(alphabet.contains("!"))
    }

    func testMapToPasswordContainsRequiredCharacterClasses() {
        let policy = PasswordPolicy(length: 12,
                                     useLower: true,
                                     useUpper: true,
                                     useDigits: true,
                                     useSymbols: true,
                                     avoidAmbiguous: true,
                                     version: 1)
        let material = Data((0..<128).map { UInt8($0) })
        let password = PasswordEngine.mapToPassword(material, policy: policy)
        XCTAssertEqual(password.count, 12)
        XCTAssertTrue(password.contains(where: { CharacterSet.lowercaseLetters.contains($0.unicodeScalars.first!) }))
        XCTAssertTrue(password.contains(where: { CharacterSet.uppercaseLetters.contains($0.unicodeScalars.first!) }))
        XCTAssertTrue(password.contains(where: { CharacterSet.decimalDigits.contains($0.unicodeScalars.first!) }))
        XCTAssertTrue(password.contains(where: { "!#$%&*+-.:;<=>?@^_~".contains($0) }))
    }

    func testMapToPasswordUsesFallbackAlphabetWhenAllDisabled() {
        let policy = PasswordPolicy(length: 8,
                                     useLower: false,
                                     useUpper: false,
                                     useDigits: false,
                                     useSymbols: false,
                                     avoidAmbiguous: true,
                                     version: 1)
        let material = Data((0..<32).map { UInt8($0) })
        let password = PasswordEngine.mapToPassword(material, policy: policy)
        XCTAssertEqual(password.count, 8)
        XCTAssertTrue(password.allSatisfy { $0.isLetter || $0.isNumber })
    }
}
