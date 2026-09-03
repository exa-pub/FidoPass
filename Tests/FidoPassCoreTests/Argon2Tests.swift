import XCTest
@testable import FidoPassCore

/// The argon2id wrapper against the reference command-line tool.
///
/// The vectors were produced by `argon2` from `P-H-C/phc-winner-argon2` — the same code that
/// is vendored, but run as an independent binary — so a mismatch here means the wrapper
/// passes something wrong, not that the algorithm drifted. The parameters are the `keyv1`
/// contract: if `testParametersAreFrozen` fails, every fingerprint ever shown has changed.
final class Argon2Tests: XCTestCase {

    private let password = Data("fidopass://keyv1?nonce=abc&pubkey=def&idfp=ghi".utf8)
    private let salt = Data("fidopass-keyfp-v1".utf8)

    func testParametersAreFrozen() {
        XCTAssertEqual(Argon2.Parameters.v1, Argon2.Parameters(timeCost: 1, memoryKiB: 32_768, lanes: 1))
        XCTAssertGreaterThanOrEqual(salt.count, Argon2.minimumSaltByteCount)
    }

    /// `printf '%s' '<password>' | argon2 fidopass-keyfp-v1 -id -t 1 -m 15 -p 1 -l 6 -r`
    func testSixByteTagMatchesTheReferenceTool() throws {
        let tag = try Argon2.id(password: password, salt: salt, parameters: .v1, outputByteCount: 6)
        XCTAssertEqual(tag.hexString, "1c6704c8a388")
    }

    /// The same, with `-l 32`. Not a prefix of the 6-byte tag: the length is an input.
    func testThirtyTwoByteTagMatchesTheReferenceTool() throws {
        let tag = try Argon2.id(password: password, salt: salt, parameters: .v1, outputByteCount: 32)
        XCTAssertEqual(tag.hexString, "952890e7fb7be658311d4b55af3acc839c6cae48dd3f3e41095a15f45fd84d46")
        XCTAssertNotEqual(tag.prefix(6).hexString, "1c6704c8a388")
    }

    func testDifferentSaltsGiveDifferentTags() throws {
        let one = try Argon2.id(password: password, salt: salt, outputByteCount: 16)
        let other = try Argon2.id(password: password, salt: Data("fidopass-other-v1".utf8), outputByteCount: 16)
        XCTAssertNotEqual(one, other)
    }

    func testDifferentParametersGiveDifferentTags() throws {
        let one = try Argon2.id(password: password, salt: salt, parameters: .v1, outputByteCount: 16)
        let other = try Argon2.id(password: password,
                                  salt: salt,
                                  parameters: Argon2.Parameters(timeCost: 2, memoryKiB: 16_384, lanes: 1),
                                  outputByteCount: 16)
        XCTAssertNotEqual(one, other)
    }

    /// Prints how long one computation takes on this machine. Skipped unless asked for: the
    /// constants are frozen, and a CI runner's timing has nothing to say about them.
    ///
    /// `FIDOPASS_CALIBRATE=1 swift test --filter Argon2Tests/testCalibration`
    func testCalibration() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FIDOPASS_CALIBRATE"] == "1",
                          "set FIDOPASS_CALIBRATE=1 to measure argon2id on this machine")
        var timings: [TimeInterval] = []
        for _ in 0..<5 {
            let start = Date()
            _ = try Argon2.id(password: password, salt: salt, outputByteCount: 6)
            timings.append(Date().timeIntervalSince(start))
        }
        let median = timings.sorted()[timings.count / 2]
        print("argon2id \(Argon2.Parameters.v1): median \(Int(median * 1000)) ms over \(timings.count) runs")
    }
}
