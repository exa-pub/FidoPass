import XCTest
@testable import FidoPassCore

final class PasswordPolicyTests: XCTestCase {

    func testLengthIsClampedOnInit() {
        XCTAssertEqual(PasswordPolicy(length: 0).length, PasswordPolicy.lengthRange.lowerBound)
        XCTAssertEqual(PasswordPolicy(length: -5).length, PasswordPolicy.lengthRange.lowerBound)
        XCTAssertEqual(PasswordPolicy(length: 4).length, PasswordPolicy.lengthRange.lowerBound)
        XCTAssertEqual(PasswordPolicy(length: 10_000).length, PasswordPolicy.lengthRange.upperBound)
    }

    func testValidLengthsAreUntouched() {
        for length in [8, 12, 16, 20, 32, 128] {
            XCTAssertEqual(PasswordPolicy(length: length).length, length)
        }
    }

    func testDecodingClampsLength() throws {
        let json = """
        {"length":0,"useLower":true,"useUpper":true,"useDigits":true,"useSymbols":true,"avoidAmbiguous":true,"version":1}
        """
        let policy = try JSONDecoder().decode(PasswordPolicy.self, from: Data(json.utf8))
        XCTAssertEqual(policy.length, PasswordPolicy.lengthRange.lowerBound)
    }

    func testRoundTripPreservesValidPolicy() throws {
        let original = PasswordPolicy(length: 24, useLower: true, useUpper: false, useDigits: true, useSymbols: false, version: 1)
        let decoded = try JSONDecoder().decode(PasswordPolicy.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    /// Regression for the crash that a zero length used to cause: the engine divided by
    /// the number of produced characters while topping up character classes.
    func testEngineSurvivesZeroLength() {
        var policy = PasswordPolicy()
        policy.length = 0 // bypasses the initialiser's clamping
        XCTAssertEqual(PasswordEngine.mapToPassword(Data(repeating: 0xAB, count: 64), policy: policy), "")
    }
}
