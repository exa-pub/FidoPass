import XCTest
@testable import FidoPassCore

/// The backup is what a person keeps on paper. Two generations of it exist: 44 characters
/// from versions that predate identities, 64 from this one. Both have to parse, and the
/// difference has to be visible to the code that handles them.
final class PortableBackupTests: XCTestCase {

    private let masterKey = Data((0..<32).map { UInt8(0xF0 &- $0) })
    private let identity = AccountIdentity(bytes: Data((0..<16).map { UInt8($0 &* 3) }))!

    func testCurrentBackupRoundTrips() throws {
        let backup = try XCTUnwrap(PortableBackup(masterKey: masterKey, identity: identity))
        XCTAssertFalse(backup.isLegacy)
        XCTAssertEqual(backup.base64.count, 64)
        XCTAssertEqual(Data(base64Encoded: backup.base64)?.count, 48)

        let parsed = try XCTUnwrap(PortableBackup(base64: backup.base64))
        XCTAssertEqual(parsed, backup)
        XCTAssertEqual(parsed.masterKey, masterKey)
        XCTAssertEqual(parsed.identity, identity)
    }

    /// The 44-character form is what every released version printed. It parses, and it says
    /// what it is.
    func testLegacyBackupRoundTripsWithoutAnIdentity() throws {
        let legacy = masterKey.base64EncodedString()
        XCTAssertEqual(legacy.count, 44)
        let parsed = try XCTUnwrap(PortableBackup(base64: legacy))
        XCTAssertTrue(parsed.isLegacy)
        XCTAssertNil(parsed.identity)
        XCTAssertEqual(parsed.masterKey, masterKey)
        XCTAssertEqual(parsed.base64, legacy, "a legacy backup re-encodes as itself")
    }

    func testWithIdentityKeepsTheMasterKey() throws {
        let legacy = try XCTUnwrap(PortableBackup(base64: masterKey.base64EncodedString()))
        let upgraded = legacy.withIdentity(identity)
        XCTAssertFalse(upgraded.isLegacy)
        XCTAssertEqual(upgraded.masterKey, masterKey)
        XCTAssertEqual(upgraded.identity, identity)
        XCTAssertEqual(upgraded.base64.count, 64)
    }

    /// Any other length would derive different passwords, silently — a truncated paste must
    /// be refused, not padded. The 44-byte form an unreleased build printed is refused too.
    func testOtherLengthsAreRejected() {
        for count in [0, 16, 31, 33, 43, 44, 47, 49, 64] {
            XCTAssertNil(PortableBackup(base64: Data(repeating: 0x11, count: count).base64EncodedString()),
                         "\(count) bytes is not a backup")
        }
        XCTAssertNil(PortableBackup(base64: "definitely not base64 %%%"))
        XCTAssertNil(PortableBackup(masterKey: Data(repeating: 1, count: 31), identity: nil))
    }

    /// Printed on paper and wrapped by whatever it was pasted through.
    func testWhitespaceIsIgnored() throws {
        let backup = try XCTUnwrap(PortableBackup(masterKey: masterKey, identity: identity))
        let text = backup.base64
        let wrapped = String(text.prefix(20)) + "\n  " + String(text.dropFirst(20).prefix(20)) + " \t" + String(text.dropFirst(40)) + "\n"
        XCTAssertEqual(PortableBackup(base64: wrapped), backup)
    }
}
