import XCTest
@testable import FidoPassCore
import TestSupport

/// Contract-level properties of derivation, complementing the pinned values in
/// `GoldenVectorsTests`: the same input must always produce the same password, and every
/// input that is meant to change the password must actually change it.
final class DerivationContractTests: XCTestCase {

    func testSameInputAlwaysProducesSamePassword() throws {
        let generator = PasswordGenerator(secretDerivationService: Self.secretService())
        let account = AccountHandle.fixture(id: "acct")

        let first = try generator.generatePassword(account,
                                                   label: "vault",
                                                   parameters: .v1,
                                                   pinProvider: nil)
        for _ in 0..<200 {
            let next = try generator.generatePassword(account,
                                                      label: "vault",
                                                      parameters: .v1,
                                                      pinProvider: nil)
            XCTAssertEqual(next, first)
        }
    }

    /// Every component of the salt must reach the output. A component that silently stops
    /// contributing would make distinct accounts or labels collide onto one password.
    func testSaltComponentsAllAffectTheResult() {
        let base = SaltFactory.residentSalt(label: "vault", rpId: "fidopass.local", accountId: "acct", revision: 1)

        XCTAssertNotEqual(base, SaltFactory.residentSalt(label: "other", rpId: "fidopass.local", accountId: "acct", revision: 1),
                          "label must affect the salt")
        XCTAssertNotEqual(base, SaltFactory.residentSalt(label: "vault", rpId: "fidopass.portable", accountId: "acct", revision: 1),
                          "rpId must affect the salt")
        XCTAssertNotEqual(base, SaltFactory.residentSalt(label: "vault", rpId: "fidopass.local", accountId: "other", revision: 1),
                          "accountId must affect the salt")
        XCTAssertNotEqual(base, SaltFactory.residentSalt(label: "vault", rpId: "fidopass.local", accountId: "acct", revision: 2),
                          "revision must affect the salt")
    }

    /// Field separators must not be forgeable: concatenating components differently has to
    /// yield a different salt, otherwise ("ab", "c") and ("a", "bc") would collide.
    func testSaltComponentsAreUnambiguouslySeparated() {
        let left = SaltFactory.residentSalt(label: "b", rpId: "fidopass.local", accountId: "a", revision: 1)
        let right = SaltFactory.residentSalt(label: "", rpId: "fidopass.local", accountId: "a|b", revision: 1)
        XCTAssertNotEqual(left, right)
    }

    func testPolicyChangesProduceDifferentPasswords() throws {
        let generator = PasswordGenerator(secretDerivationService: Self.secretService())
        let account = AccountHandle.fixture(id: "acct")

        let standard = try generator.generatePassword(account,
                                                      label: "vault",
                                                      parameters: .v1,
                                                      pinProvider: nil)
        let noSymbols = try generator.generatePassword(account,
                                                       label: "vault",
                                                       parameters: DerivationParameters(revision: 1, policy: PasswordPolicy(length: 20, useSymbols: false)),
                                                       pinProvider: nil)
        let otherVersion = try generator.generatePassword(account,
                                                          label: "vault",
                                                          parameters: DerivationParameters(revision: 1, policy: PasswordPolicy(length: 20, version: 2)),
                                                          pinProvider: nil)
        XCTAssertNotEqual(standard, noSymbols)
        XCTAssertNotEqual(standard, otherVersion, "policy.version feeds HKDF info and must change the output")
    }

    func testPortableLabelIsolation() {
        XCTAssertNotEqual(SaltFactory.portableLabelSalt("vault"),
                          SaltFactory.portableLabelSalt("other"))
        XCTAssertNotEqual(SaltFactory.portableLabelSalt("vault"),
                          SaltFactory.residentSalt(label: "vault", rpId: "fidopass.local", accountId: "acct", revision: 1),
                          "portable and resident namespaces must not collide")
    }

    private static func secretService() -> MockSecretDerivationService {
        let service = MockSecretDerivationService()
        service.deriveSecretClosure = { _, _, _, _ in Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 5) }) }
        service.deriveFixedClosure = { _, _ in Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) }) }
        return service
    }
}
