import XCTest
@testable import FidoPassCore

/// The rules a key PIN must satisfy.
///
/// Enforced here so a PIN that was never going to work is refused in the field rather than by
/// the key — which matters most when changing a PIN, where a doomed attempt would spend one of
/// the eight that stand between the key and a permanent lock-out.
final class PinPolicyTests: XCTestCase {

    private let policy = PinPolicy()

    func testTheProtocolFloorIsFourBytes() {
        XCTAssertEqual(policy.validate("123"), .tooShort(min: 4))
        XCTAssertNil(policy.validate("1234"))
    }

    /// libfido2 pads the PIN into a 64-byte buffer with a trailing NUL (`src/pin.c`), so 63
    /// is the ceiling and 64 is refused before anything is sent.
    func testTheCeilingIsSixtyThreeBytes() {
        XCTAssertNil(policy.validate(String(repeating: "a", count: 63)))
        XCTAssertEqual(policy.validate(String(repeating: "a", count: 64)), .tooLong(max: 63))
    }

    /// Bytes, not characters. Counting characters would let a PIN through that the key then
    /// rejects — and, at the short end, would accept a three-byte PIN spelled in two glyphs.
    func testLengthIsCountedInUTF8Bytes() {
        XCTAssertNil(policy.validate("паро"), "four characters, eight bytes — comfortably valid")
        // 16 emoji at 4 bytes each is 64: one character short of the glyph limit, one byte
        // over the real one.
        XCTAssertEqual(policy.validate(String(repeating: "🔑", count: 16)), .tooLong(max: 63))
    }

    func testAKeyCanRaiseTheMinimum() {
        let strict = PinPolicy(minLengthBytes: 6)
        XCTAssertEqual(strict.validate("12345"), .tooShort(min: 6))
        XCTAssertNil(strict.validate("123456"))
    }

    /// A key that declares a minimum below the protocol floor is describing something CTAP2
    /// will not honour anyway.
    func testAMinimumBelowTheFloorIsIgnored() {
        XCTAssertEqual(PinPolicy(minLengthBytes: 1).minLengthBytes, 4)
    }

    /// Some keys accept a "change" to the same value, which is worse than refusing it: the
    /// user believes the PIN was rotated when it was not.
    func testAChangeToTheSameValueIsNotAChange() {
        XCTAssertEqual(policy.validate("123456", oldPIN: "123456"), .sameAsOld)
        XCTAssertNil(policy.validate("123456", oldPIN: "654321"))
    }

    func testAnEmptyPinIsItsOwnCase() {
        XCTAssertEqual(policy.validate(""), .empty)
    }

    /// The status a key reports is what the UI has to enforce.
    func testTheStatusCarriesTheKeysOwnPolicy() {
        let declared = DeviceStatus(pinRetriesRemaining: 8,
                                    hasPIN: false,
                                    supportsHmacSecret: true,
                                    remainingResidentKeys: 25,
                                    minPINLength: 8)
        XCTAssertEqual(declared.pinPolicy.minLengthBytes, 8)

        let silent = DeviceStatus(pinRetriesRemaining: 8,
                                  hasPIN: false,
                                  supportsHmacSecret: true,
                                  remainingResidentKeys: 25)
        XCTAssertEqual(silent.pinPolicy.minLengthBytes, PinPolicy.ctapFloor)
    }
}

/// The libfido2 status codes these flows turn on.
///
/// Pinned by their numeric values: the UI reacts differently to "the key rejected this PIN"
/// (no attempt spent) than to "wrong PIN" (one gone), and that distinction is only as good as
/// the mapping.
final class FidoStatusMappingTests: XCTestCase {

    func testTheCodesTheKeyManagementFlowsDependOn() {
        XCTAssertEqual(FidoStatus(code: 0x30), .notAllowed)
        XCTAssertEqual(FidoStatus(code: 0x37), .pinPolicyViolation)
        XCTAssertEqual(FidoStatus(code: 0x33), .pinAuthInvalid)
    }

    func testUnknownCodesSurviveAsThemselves() {
        XCTAssertEqual(FidoStatus(code: 0x7F), .other(0x7F))
    }
}
