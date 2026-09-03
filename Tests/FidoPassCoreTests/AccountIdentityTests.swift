import XCTest
@testable import FidoPassCore

/// The identity is shown, typed back in, printed on a recovery sheet and compared across
/// two keys by eye — so its text form has to be forgiving to read and strict to parse.
final class AccountIdentityTests: XCTestCase {

    private let ramp = Data((0..<16).map { UInt8($0) })

    func testHexRoundTrip() throws {
        let identity = try XCTUnwrap(AccountIdentity(bytes: ramp))
        XCTAssertEqual(identity.hex, "000102030405060708090a0b0c0d0e0f")
        XCTAssertEqual(identity.groupedHex, "0001 0203 0405 0607 0809 0a0b 0c0d 0e0f")
        XCTAssertEqual(AccountIdentity(hex: identity.hex), identity)
        XCTAssertEqual(AccountIdentity(hex: identity.groupedHex), identity)
    }

    /// People read these out and type them back: whatever grouping they used has to parse.
    func testParsingAcceptsSeparatorsAndEitherCase() {
        let expected = AccountIdentity(bytes: ramp)
        XCTAssertEqual(AccountIdentity(hex: "0001-0203-0405-0607-0809-0A0B-0C0D-0E0F"), expected)
        XCTAssertEqual(AccountIdentity(hex: "00:01:02:03:04:05:06:07:08:09:0a:0b:0c:0d:0e:0f"), expected)
        XCTAssertEqual(AccountIdentity(hex: "  0001 0203\n0405 0607 0809 0a0b 0c0d 0e0f  "), expected)
    }

    func testParsingRejectsAnythingThatIsNotSixteenBytesOfHex() {
        XCTAssertNil(AccountIdentity(hex: ""))
        XCTAssertNil(AccountIdentity(hex: "000102030405060708090a0b0c0d0e"), "15 bytes")
        XCTAssertNil(AccountIdentity(hex: "000102030405060708090a0b0c0d0e0f10"), "17 bytes")
        XCTAssertNil(AccountIdentity(hex: "000102030405060708090a0b"), "12 bytes — the size an unreleased build used; not read")
        XCTAssertNil(AccountIdentity(hex: "zz0102030405060708090a0b0c0d0e0f"), "not hex")
        // `UInt8(_:radix:)` accepts a sign; the identity must not.
        XCTAssertNil(AccountIdentity(hex: "+10102030405060708090a0b0c0d0e0f"))
        XCTAssertNil(AccountIdentity(hex: "0x0102030405060708090a0b0c0d0e0f"))
    }

    func testBytesInitEnforcesTheLength() {
        XCTAssertNil(AccountIdentity(bytes: Data(repeating: 1, count: 15)))
        XCTAssertNil(AccountIdentity(bytes: Data(repeating: 1, count: 17)))
        XCTAssertNil(AccountIdentity(bytes: Data(repeating: 1, count: 12)))
        XCTAssertNotNil(AccountIdentity(bytes: Data(repeating: 1, count: 16)))
    }

    /// A slice keeps the indices of its parent; the identity must not, or `bytes[0]` on it
    /// would trap.
    func testBytesAreCopiedOutOfASlice() throws {
        let larger = Data((0..<48).map { UInt8($0) })
        let identity = try XCTUnwrap(AccountIdentity(bytes: larger.suffix(16)))
        XCTAssertEqual(identity.bytes[0], 32)
        XCTAssertEqual(identity.hex, "202122232425262728292a2b2c2d2e2f")
    }

    func testRandomIsSixteenBytesAndNotRepeated() {
        let first = AccountIdentity.random()
        let second = AccountIdentity.random()
        XCTAssertEqual(first.bytes.count, 16)
        XCTAssertEqual(first.bytes.count, AccountIdentity.byteCount)
        XCTAssertNotEqual(first, second)
    }

    /// A v1 local account's identity is a function of its credential id and nothing else,
    /// so it is the same on every launch and every Mac. Pinned: changing the derivation
    /// would make every printed recovery sheet disagree with the screen.
    func testDerivedIdentityIsPinned() {
        let identity = AccountIdentity.derived(fromCredentialId: Data("cred".utf8))
        XCTAssertEqual(identity.hex, "55d91a3561684b32df5e58a0d91968b9")
        XCTAssertEqual(AccountIdentity.derived(fromCredentialId: Data("cred".utf8)), identity)
        XCTAssertNotEqual(AccountIdentity.derived(fromCredentialId: Data("other".utf8)), identity)
    }

    /// JSON carries the hex, not a base64 blob that would look like key material next to
    /// the withheld name.
    func testEncodesAsHex() throws {
        let identity = try XCTUnwrap(AccountIdentity(bytes: ramp))
        let json = String(decoding: try JSONEncoder().encode([identity]), as: UTF8.self)
        XCTAssertEqual(json, "[\"000102030405060708090a0b0c0d0e0f\"]")
        let decoded = try JSONDecoder().decode([AccountIdentity].self, from: Data(json.utf8))
        XCTAssertEqual(decoded, [identity])
        XCTAssertThrowsError(try JSONDecoder().decode([AccountIdentity].self, from: Data("[\"nope\"]".utf8)))
    }
}
