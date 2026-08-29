import XCTest
@testable import FidoPassCore
import TestSupport

/// Frozen outputs of the password-derivation pipeline.
///
/// Derivation is a compatibility contract: every stored password a user relies on is
/// reproduced from these code paths. Changing any of them silently invalidates real
/// logins, so the expected values below are pinned to the behaviour shipped with
/// `PasswordPolicy.version == 1`.
///
/// If a change here makes a test fail, the change is wrong unless it is gated behind a
/// new policy version. Never update the expectations to match new behaviour.
///
/// Three levels are pinned separately because each can break independently:
/// 1. `SaltFactory`      — how label / account / rp / revision enter the derivation.
/// 2. `PasswordEngine`   — how key material maps onto characters.
/// 3. `PasswordGenerator`— how the two combine, including the portable branch.
final class GoldenVectorsTests: XCTestCase {

    // MARK: - Level 1: salts

    /// Salts are the only place where label, account id, rp id and revision affect the
    /// result, so they need byte-exact coverage. The generator vectors below cannot
    /// cover this: they mock secret derivation out, which is where salts are consumed.
    func testSaltVectors() {
        let resident: [(label: String, rpId: String, accountId: String, revision: Int, expected: String)] = [
            ("default",    "fidopass.local",    "acct",  1, "3e344e45ab2332b1b6ebed8c0dce9cf02c8fb24961307c9ec47ba1e1b8fc73f9"),
            ("default",    "fidopass.local",    "acct",  2, "b2f4b8dc84a3bc709e296300dcd95b11864d6060a53bb28fd66997c73107ac90"),
            ("github.com", "fidopass.local",    "acct",  1, "cecfd652320c0b1b95a80f35bdd0867cb8345202b88e52ceefb0ed833dfd6204"),
            ("github.com", "fidopass.local",    "other", 1, "3dca97025c5222982e07e1c497d8f013556eda2b3fc00c2ee2e1df962926b3f6"),
            ("github.com", "fidopass.portable", "acct",  1, "2b4f242d33a6db293eff1ba49464d8a0bdbb72857f39cdc91c9849cf9313edc0"),
            ("",           "fidopass.local",    "acct",  1, "3c89ed8a73cfe4dd748a4c090d544a7f337d52c2723cd1e8ddd9c1c3dcc0f311"),
            ("vault",      "fidopass.local",    "acct",  7, "33daf100aa04f817f26f6d662b609cadf49d00fd5831c4702766c2f47d4311f7")
        ]
        for vector in resident {
            let salt = SaltFactory.residentSalt(label: vector.label,
                                                rpId: vector.rpId,
                                                accountId: vector.accountId,
                                                revision: vector.revision)
            XCTAssertEqual(Self.hex(salt), vector.expected,
                           "residentSalt(\(vector.label), \(vector.rpId), \(vector.accountId), \(vector.revision))")
        }

        XCTAssertEqual(Self.hex(SaltFactory.fixedComponentSalt()),
                       "2f39b89f942cdf6d13581e274aa97b9cc591a9b7df2346caea3160a6a56a910d")

        let portable: [(label: String, expected: String)] = [
            ("",           "09ec36cfdc49bd24f0feb77d7bbb8bf33e8bef1343ba6a80de04cd2a115cb658"),
            ("default",    "ff6ed56457877d04ca8186d7ce5b2ccb9b6c4c1c157e03560bd6955bee924758"),
            ("github.com", "7dc424d3765c57bb35efb7e6f59044f8811be0079f29d2c0459fb2e9f1ef19f2"),
            ("vault",      "6137d1d0e1eb7be06ebaebd0f6dbe73c859024b3c258f9e1fc4e693790616073")
        ]
        for vector in portable {
            XCTAssertEqual(Self.hex(SaltFactory.portableLabelSalt(vector.label)), vector.expected,
                           "portableLabelSalt(\(vector.label))")
        }
    }

    // MARK: - Level 2: character mapping

    func testEngineVectors() {
        for (materialName, material) in Self.materials {
            for (policyName, policy) in Self.policies {
                guard let expected = Self.engineExpectations["\(materialName)|\(policyName)"] else {
                    XCTFail("missing expectation for \(materialName)|\(policyName)")
                    continue
                }
                let password = PasswordEngine.mapToPassword(material, policy: policy)
                XCTAssertEqual(password, expected, "engine \(materialName)|\(policyName)")
            }
        }
    }

    // MARK: - Level 3: full generator

    func testLocalAccountVectors() throws {
        let generator = PasswordGenerator(secretDerivationService: Self.makeSecretService())
        let expectations: [(policy: String, expected: String)] = [
            ("default", "*KF<yShuz+5=y%*~TQKa"),
            ("len12",   "*KF<yShuz+5="),
            ("alnum16", "ftpHfzhuVCMJyd9e")
        ]
        for expectation in expectations {
            let policy = Self.generatorPolicies[expectation.policy]!
            // Label and revision are mocked out here on purpose: their contribution is
            // pinned by testSaltVectors. This vector pins material -> password only.
            var account = Account.fixture(id: "acct")
            account.policy = policy
            let password = try generator.generatePassword(account: account,
                                                          label: "vault",
                                                          policy: nil,
                                                          requireUV: true,
                                                          pinProvider: nil)
            XCTAssertEqual(password, expectation.expected, "local \(expectation.policy)")
        }
    }

    func testPortableAccountVectors() throws {
        let generator = PasswordGenerator(secretDerivationService: Self.makeSecretService())
        let external = Data(zip(Self.importedKey, Self.fixedComponent).map { $0 ^ $1 })
        let expectations: [(policy: String, label: String, expected: String)] = [
            ("default", "",           "&tSSV4*Sa5RrMs.Gp!k_"),
            ("default", "default",    "RHV-jJ>6gJQnuefr<kw4"),
            ("default", "github.com", "-Z=s7Ts-$+<;qhCbaxfH"),
            ("len12",   "",           "&tSSV4*Sa5Rr"),
            ("len12",   "default",    "RHV-jJ>6gJQn"),
            ("len12",   "github.com", "-Z=s7Ts-$+<;"),
            ("alnum16", "",           "ePdzgKXSSMy8uNjG"),
            ("alnum16", "default",    "R5gD26K6gsQnQef8"),
            ("alnum16", "github.com", "Dm6NPT9ZygHGKDCT")
        ]
        for expectation in expectations {
            var account = Account.fixture(id: "pacct",
                                          kind: .portable,
                                          portable: PortablePayload(external: external))
            account.policy = Self.generatorPolicies[expectation.policy]!
            let password = try generator.generatePassword(account: account,
                                                          label: expectation.label,
                                                          policy: nil,
                                                          requireUV: true,
                                                          pinProvider: nil)
            XCTAssertEqual(password, expectation.expected,
                           "portable \(expectation.policy)|\(expectation.label)")
        }
    }

    // MARK: - Fixtures

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static let secret = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 5) })
    private static let fixedComponent = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) })
    private static let importedKey = Data((0..<32).map { UInt8(truncatingIfNeeded: 0xF0 &- $0) })

    private static func makeSecretService() -> MockSecretDerivationService {
        let service = MockSecretDerivationService()
        service.deriveSecretClosure = { _, _, _, _ in secret }
        service.deriveFixedClosure = { _, _, _ in fixedComponent }
        return service
    }

    private static let materials: [(String, Data)] = [
        ("fill00", Data(repeating: 0x00, count: 128)),
        ("fill5A", Data(repeating: 0x5A, count: 128)),
        ("fillFF", Data(repeating: 0xFF, count: 128)),
        ("ramp",   Data((0..<192).map { UInt8(truncatingIfNeeded: $0) }))
    ]

    private static let policies: [(String, PasswordPolicy)] = [
        ("all/8",        PasswordPolicy(length: 8)),
        ("all/12",       PasswordPolicy(length: 12)),
        ("all/20",       PasswordPolicy(length: 20)),
        ("all/32",       PasswordPolicy(length: 32)),
        ("lower/16",     PasswordPolicy(length: 16, useLower: true, useUpper: false, useDigits: false, useSymbols: false)),
        ("upper/16",     PasswordPolicy(length: 16, useLower: false, useUpper: true, useDigits: false, useSymbols: false)),
        ("digits/16",    PasswordPolicy(length: 16, useLower: false, useUpper: false, useDigits: true, useSymbols: false)),
        ("symbols/16",   PasswordPolicy(length: 16, useLower: false, useUpper: false, useDigits: false, useSymbols: true)),
        ("noSymbols/20", PasswordPolicy(length: 20, useLower: true, useUpper: true, useDigits: true, useSymbols: false)),
        ("alnum/12",     PasswordPolicy(length: 12, useLower: true, useUpper: true, useDigits: true, useSymbols: false)),
        ("none/8",       PasswordPolicy(length: 8, useLower: false, useUpper: false, useDigits: false, useSymbols: false)),
        ("v2/20",        PasswordPolicy(length: 20, version: 2))
    ]

    private static let generatorPolicies: [String: PasswordPolicy] = [
        "default": PasswordPolicy(),
        "len12":   PasswordPolicy(length: 12),
        "alnum16": PasswordPolicy(length: 16, useLower: true, useUpper: true, useDigits: true, useSymbols: false)
    ]

    private static let engineExpectations: [String: String] = [
        "fill00|all/8":        "!aaaaaaa",
        "fill00|all/12":       "!aaaaaaaaaaa",
        "fill00|all/20":       "!aaaaaaaaaaaaaaaaaaa",
        "fill00|all/32":       "!aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "fill00|lower/16":     "aaaaaaaaaaaaaaaa",
        "fill00|upper/16":     "AAAAAAAAAAAAAAAA",
        "fill00|digits/16":    "2222222222222222",
        "fill00|symbols/16":   "!!!!!!!!!!!!!!!!",
        "fill00|noSymbols/20": "2aaaaaaaaaaaaaaaaaaa",
        "fill00|alnum/12":     "2aaaaaaaaaaa",
        "fill00|none/8":       "aaaaaaaa",
        "fill00|v2/20":        "!aaaaaaaaaaaaaaaaaaa",

        "fill5A|all/8":        "uu?uuuuu",
        "fill5A|all/12":       "uuuuuu?uuuuu",
        "fill5A|all/20":       "uuuuuuuuuu?uuuuuuuuu",
        "fill5A|all/32":       "uuuuuuuuuuuuuuuuuuuuuuuuuu?uuuuu",
        "fill5A|lower/16":     "yyyyyyyyyyyyyyyy",
        "fill5A|upper/16":     "YYYYYYYYYYYYYYYY",
        "fill5A|digits/16":    "4444444444444444",
        "fill5A|symbols/16":   "????????????????",
        "fill5A|noSymbols/20": "QQQQQQQQQQ4QQQQQQQQQ",
        "fill5A|alnum/12":     "QQQQQQ4QQQQQ",
        "fill5A|none/8":       "QQQQQQQQ",
        "fill5A|v2/20":        "uuuuuuuuuu?uuuuuuuuu",

        "fillFF|all/8":        "aaaaaaa.",
        "fillFF|all/12":       "aaa.aaaaaaaa",
        "fillFF|all/20":       "aaaaaaaaaaaaaaa.aaaa",
        "fillFF|all/32":       "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.",
        "fillFF|lower/16":     "aaaaaaaaaaaaaaaa",
        "fillFF|upper/16":     "AAAAAAAAAAAAAAAA",
        "fillFF|digits/16":    "9999999999999999",
        "fillFF|symbols/16":   "!!!!!!!!!!!!!!!!",
        "fillFF|noSymbols/20": "aaaaaaaaaaaaaaa9aaaa",
        "fillFF|alnum/12":     "aaa9aaaaaaaa",
        "fillFF|none/8":       "aaaaaaaa",
        "fillFF|v2/20":        "aaaaaaaaaaaaaaa.aaaa",

        "ramp|all/8":          "aJ3;efgh",
        "ramp|all/12":         "aJ3;efghjkmn",
        "ramp|all/20":         "aJ3;efghjkmnpqrstuvw",
        "ramp|all/32":         "ab3;efghjkmnpqrstuvwxyzABCDEFGHJ",
        "ramp|lower/16":       "abcdefghjkmnpqrs",
        "ramp|upper/16":       "ABCDEFGHJKMNPQRS",
        "ramp|digits/16":      "2345678923456789",
        "ramp|symbols/16":     "!#$%&*+-.:;<=>?@",
        "ramp|noSymbols/20":   "aJ3defghjkmnpqrstuvw",
        "ramp|alnum/12":       "aJ3defghjkmn",
        "ramp|none/8":         "abcdefgh",
        "ramp|v2/20":          "aJ3;efghjkmnpqrstuvw"
    ]
}
