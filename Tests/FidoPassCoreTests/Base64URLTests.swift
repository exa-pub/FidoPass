import XCTest
@testable import FidoPassCore

final class Base64URLTests: XCTestCase {

    func testRoundTripOfEveryShortLength() {
        for count in 0...4 {
            let bytes = Data((0..<count).map { UInt8(0xF0 + $0) })
            let encoded = Base64URL.encode(bytes)
            XCTAssertFalse(encoded.contains("="), "no padding for \(count) bytes")
            XCTAssertEqual(Base64URL.decode(encoded), bytes)
        }
    }

    func testUsesTheURLAlphabet() {
        // 0xFB 0xFF encodes to "+/8=" in standard base64.
        let encoded = Base64URL.encode(Data([0xFB, 0xFF]))
        XCTAssertEqual(encoded, "-_8")
        XCTAssertEqual(Base64URL.decode("-_8"), Data([0xFB, 0xFF]))
    }

    func testStandardAlphabetAndPaddingAreRefused() {
        XCTAssertNil(Base64URL.decode("+/8"), "standard alphabet is not the URL alphabet")
        XCTAssertNil(Base64URL.decode("-_8="), "padding is never written, so it is never read")
        XCTAssertNil(Base64URL.decode("ab c"))
        XCTAssertNil(Base64URL.decode("ab\ncd"))
    }

    func testImpossibleLengthIsRefused() {
        XCTAssertNil(Base64URL.decode("abcde"), "no byte string encodes to 4n+1 characters")
    }

    func testThirtyTwoBytesAreFortyThreeCharacters() {
        XCTAssertEqual(Base64URL.encode(Data(repeating: 0xAB, count: 32)).count, 43)
        XCTAssertEqual(Base64URL.encode(Data(repeating: 0xAB, count: 16)).count, 22)
    }
}
