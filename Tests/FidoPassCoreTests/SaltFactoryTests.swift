import XCTest
@testable import FidoPassCore

final class SaltFactoryTests: XCTestCase {

    // MARK: - v1, frozen

    func testResidentSaltDependsOnRevision() {
        let base = SaltFactory.residentSalt(label: "example",
                                            rpId: "fidopass.local",
                                            accountId: "acct",
                                            revision: 1)
        let updated = SaltFactory.residentSalt(label: "example",
                                               rpId: "fidopass.local",
                                               accountId: "acct",
                                               revision: 2)
        XCTAssertNotEqual(base, updated)
    }

    func testResidentSaltIsDeterministic() {
        let first = SaltFactory.residentSalt(label: "label",
                                             rpId: "rp",
                                             accountId: "acct",
                                             revision: 3)
        let second = SaltFactory.residentSalt(label: "label",
                                              rpId: "rp",
                                              accountId: "acct",
                                              revision: 3)
        XCTAssertEqual(first, second)
    }

    func testFixedComponentSaltIsStable() {
        let first = SaltFactory.fixedComponentSalt()
        let second = SaltFactory.fixedComponentSalt()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(SaltFactory.fixedComponentSalt(format: .v1), first)
    }

    func testPortableSaltNamespaceIsolation() {
        let base = SaltFactory.portableLabelSalt("example")
        let other = SaltFactory.residentSalt(label: "example",
                                             rpId: "fidopass.local",
                                             accountId: "acct",
                                             revision: 1)
        XCTAssertNotEqual(base, other)
    }

    // MARK: - v2: what a browser would ask the key

    /// Frozen. `SHA-256("WebAuthn PRF" ‖ 0x00 ‖ input)` is what the `prf` extension hands the
    /// authenticator; a page evaluating `prf` over `fidopass|fixed|v2` gets the same 32 bytes
    /// back as this app only if this salt is exactly that. Computed independently with
    /// `printf | shasum`.
    func testPrfSaltMatchesTheWebAuthnWrapping() {
        let salt = SaltFactory.prfSalt(input: Data("fidopass|fixed|v2".utf8))
        XCTAssertEqual(salt.hexString, "5d267585fe91a12df6e27959f2be9e38fc12c0f55b4077826211f36b161af4fd")
        XCTAssertEqual(SaltFactory.fixedComponentSaltV2(), salt)
        XCTAssertEqual(SaltFactory.fixedComponentSalt(format: .v2), salt)
    }

    /// Frozen: the v2 local password salt for label `vault`, revision 1 — `prf` over
    /// `fidopass|pw|v2|vault` followed by the revision as four big-endian bytes.
    func testLocalPasswordSaltIsPinned() {
        XCTAssertEqual(SaltFactory.localPasswordSalt(label: "vault", revision: 1).hexString,
                       "346ef5e42fd931efdcfedc85cdbd31b3d1b5289e337c17a2dc604f8954419a7f")
    }

    func testLocalPasswordSaltDependsOnLabelAndRevisionOnly() {
        let base = SaltFactory.localPasswordSalt(label: "vault", revision: 1)
        XCTAssertNotEqual(base, SaltFactory.localPasswordSalt(label: "other", revision: 1))
        XCTAssertNotEqual(base, SaltFactory.localPasswordSalt(label: "vault", revision: 2))
        XCTAssertEqual(base, SaltFactory.localPasswordSalt(label: "vault", revision: 1))
        // The fixed-width revision at the end keeps the label unambiguous.
        XCTAssertNotEqual(SaltFactory.localPasswordSalt(label: "vault\u{0}", revision: 0x01000000),
                          SaltFactory.localPasswordSalt(label: "vault", revision: 1))
    }

    /// Passwords, messages and the fixed component must never share a salt.
    func testV2DomainsAreDistinct() {
        let nonce = Data(repeating: 0x42, count: 32)
        let password = SaltFactory.localPasswordSalt(label: "vault", revision: 1)
        let message = SaltFactory.messageKeySaltV2(nonce: nonce)
        let fixed = SaltFactory.fixedComponentSaltV2()
        XCTAssertNotEqual(password, message)
        XCTAssertNotEqual(password, fixed)
        XCTAssertNotEqual(message, fixed)
        XCTAssertEqual(SaltFactory.messageKeySalt(nonce: nonce, format: .v2), message)
        XCTAssertNotEqual(SaltFactory.messageKeySalt(nonce: nonce, format: .v1), message)
        XCTAssertNotEqual(message, SaltFactory.messageKeySaltV2(nonce: Data(repeating: 0x43, count: 32)))
    }

    /// The v1 salts are not wrapped and the v2 ones are: a v1 account keeps deriving with
    /// exactly what it always did.
    func testV1SaltsAreUntouchedByTheWrapping() {
        XCTAssertNotEqual(SaltFactory.fixedComponentSalt(format: .v1), SaltFactory.fixedComponentSalt(format: .v2))
        XCTAssertEqual(SaltFactory.fixedComponentSalt(format: .v1).hexString,
                       Data(SHA256.hash(data: Data("fidopass|fixed-challenge|v1".utf8))).hexString)
    }
}

import CryptoKit
