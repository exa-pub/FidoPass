import XCTest
@testable import FidoPassCore

/// `PasswordEngine.mapToPassword` intends to guarantee that every enabled character class
/// appears in the result. It does not: the top-up step overwrites characters at positions
/// derived from the same bytes, so one fix can collide with another or destroy the sole
/// representative of a class that was already satisfied. The check runs before the edits
/// and is never re-verified.
///
/// The failure rate falls off sharply with length — roughly 3% at 8 characters and
/// effectively zero at the default 20 — so this is recorded rather than fixed. Fixing it
/// changes generated passwords and must therefore ship under a new `PasswordPolicy.version`.
///
/// When that fix lands, `XCTExpectFailure` below will start reporting "expected failure
/// but none occurred" — that is the signal to delete it and let this test stand.
final class CharacterClassInvariantTests: XCTestCase {

    func testEveryEnabledClassIsPresent() {
        XCTExpectFailure("Known defect: the character-class guarantee is not upheld for short passwords")

        let policy = PasswordPolicy(length: PasswordPolicy.lengthRange.lowerBound)
        let classes: [(name: String, members: Set<Character>)] = [
            ("lower",   Set("abcdefghjkmnpqrstuvwxyz")),
            ("upper",   Set("ABCDEFGHJKMNPQRSTUVWXYZ")),
            ("digits",  Set("23456789")),
            ("symbols", Set("!#$%&*+-.:;<=>?@^_~"))
        ]

        var violations = 0
        let sampleCount = 5_000
        for seed in 0..<sampleCount {
            let password = Set(PasswordEngine.mapToPassword(Self.material(seed: seed), policy: policy))
            if classes.contains(where: { password.isDisjoint(with: $0.members) }) {
                violations += 1
            }
        }

        XCTAssertEqual(violations, 0,
                       "\(violations) of \(sampleCount) passwords are missing at least one enabled character class")
    }

    /// The property that does hold today and must keep holding: length is always exact.
    func testLengthIsAlwaysExact() {
        for length in [8, 12, 16, 20, 32] {
            let policy = PasswordPolicy(length: length)
            for seed in 0..<200 {
                XCTAssertEqual(PasswordEngine.mapToPassword(Self.material(seed: seed), policy: policy).count, length)
            }
        }
    }

    /// Characters never come from outside the configured alphabet.
    func testCharactersStayInsideAlphabet() {
        for (_, policy) in [("all", PasswordPolicy(length: 20)),
                            ("alnum", PasswordPolicy(length: 20, useSymbols: false)),
                            ("digits", PasswordPolicy(length: 20, useLower: false, useUpper: false, useSymbols: false))] {
            let alphabet = Set(PasswordEngine.alphabet(policy: policy))
            for seed in 0..<200 {
                let password = PasswordEngine.mapToPassword(Self.material(seed: seed), policy: policy)
                XCTAssertTrue(Set(password).isSubset(of: alphabet))
            }
        }
    }

    private static func material(seed: Int, count: Int = 96) -> Data {
        var out = Data()
        var state = UInt64(bitPattern: Int64(seed)) &+ 0x9E37_79B9_7F4A_7C15
        for _ in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            out.append(UInt8(truncatingIfNeeded: state >> 33))
        }
        return out
    }
}
