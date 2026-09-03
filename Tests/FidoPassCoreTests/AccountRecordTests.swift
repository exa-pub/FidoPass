import XCTest
@testable import FidoPassCore

/// The record is a frozen layout: two bytes for a local account, thirty-four for a portable
/// one, and nothing else is a record. A browser reads the same bytes out of the same blob.
final class AccountRecordTests: XCTestCase {

    private let mask = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 9 &+ 2) })

    func testLocalRecordIsTwoBytes() throws {
        let record = try XCTUnwrap(AccountRecord(kind: .local, mask: nil))
        XCTAssertEqual(record.encoded, Data([0x01, 0x00]))
        let decoded = try XCTUnwrap(AccountRecord(decoding: record.encoded))
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.kind, .local)
        XCTAssertNil(decoded.mask)
    }

    func testPortableRecordCarriesTheMask() throws {
        let record = try XCTUnwrap(AccountRecord(kind: .portable, mask: mask))
        XCTAssertEqual(record.encoded.count, 34)
        XCTAssertEqual(record.encoded.prefix(2), Data([0x01, 0x01]))
        XCTAssertEqual(record.encoded.suffix(32), mask)
        let decoded = try XCTUnwrap(AccountRecord(decoding: record.encoded))
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.mask, mask)
    }

    /// Pinned bytes: the layout a browser page will parse, and every future build must read.
    func testEncodingIsPinned() throws {
        let record = try XCTUnwrap(AccountRecord(kind: .portable, mask: Data(repeating: 0xAB, count: 32)))
        XCTAssertEqual(record.encoded.map { String(format: "%02x", $0) }.joined(),
                       "0101" + String(repeating: "ab", count: 32))
    }

    /// A kind and a mask that do not go together are not a record at all.
    func testConstructionEnforcesTheMask() {
        XCTAssertNil(AccountRecord(kind: .local, mask: mask), "a local record has no mask")
        XCTAssertNil(AccountRecord(kind: .portable, mask: nil), "a portable record needs one")
        XCTAssertNil(AccountRecord(kind: .portable, mask: Data(repeating: 1, count: 31)))
        XCTAssertNil(AccountRecord(kind: .portable, mask: Data(repeating: 1, count: 33)))
    }

    /// Any deviation is refused rather than guessed at — a future version with more fields
    /// must not be read as this one with some ignored.
    func testDecodingIsStrict() {
        XCTAssertNil(AccountRecord(decoding: Data()))
        XCTAssertNil(AccountRecord(decoding: Data([0x01])), "one byte")
        XCTAssertNil(AccountRecord(decoding: Data([0x01, 0x00, 0x00])), "a local record with a trailing byte")
        XCTAssertNil(AccountRecord(decoding: Data([0x01, 0x01]) + Data(repeating: 1, count: 31)), "33 bytes")
        XCTAssertNil(AccountRecord(decoding: Data([0x01, 0x01]) + Data(repeating: 1, count: 33)), "35 bytes")
        XCTAssertNil(AccountRecord(decoding: Data([0x00, 0x00])), "version 0")
        XCTAssertNil(AccountRecord(decoding: Data([0x02, 0x00])), "version 2 — a later build's record")
        XCTAssertNil(AccountRecord(decoding: Data([0x01, 0x02]) + Data(repeating: 1, count: 32)), "kind 2")
    }

    /// A slice keeps its parent's indices; the mask must be usable as a fresh value.
    func testMaskIsCopiedOutOfTheBlob() throws {
        let blob = Data([0x01, 0x01]) + mask
        let record = try XCTUnwrap(AccountRecord(decoding: blob.dropFirst(0)))
        XCTAssertEqual(record.mask?[0], mask[0])
    }
}
