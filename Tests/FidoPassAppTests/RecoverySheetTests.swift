import XCTest
@testable import FidoPassAppKit
import FidoPassCore
import TestSupport

final class RecoverySheetTests: XCTestCase {

    private func sheet(kind: AccountKind = .local,
                       labels: [String] = ["vault", "disk"]) -> String {
        let account = kind == .portable
            ? Account.portableFixture(id: "personal-vault")
            : Account.fixture(id: "personal-vault", kind: .local)
        return RecoverySheet(account: account,
                             parameters: DerivationParameters(revision: 3,
                                                              policy: PasswordPolicy(length: 24, useSymbols: false)),
                             labels: labels,
                             deviceDescription: "Yubico YubiKey Bio — VID 1050 PID 0402")
            .render()
    }

    /// The identity is on the sheet because it is what tells this account apart from a
    /// namesake — and it is the derived one for a local account, so the sheet and the
    /// screen agree without anything having been stored.
    func testSheetRecordsTheIdentity() {
        let expected = AccountIdentity.derived(fromCredentialId: Data("personal-vault".utf8)).groupedHex
        XCTAssertTrue(sheet(kind: .local).contains("Identity     : \(expected)"))

        let portable = Account.portableFixture(id: "personal-vault").identity!.groupedHex
        XCTAssertTrue(sheet(kind: .portable).contains("Identity     : \(portable)"))
    }

    /// An account from before identities has none to print; the sheet says what to do
    /// rather than leaving the line blank.
    func testLegacyPortableAccountIsToldToMigrate() {
        let rendered = RecoverySheet(account: Account.portableFixture(id: "old", legacy: true),
                                     parameters: .v1,
                                     labels: [],
                                     deviceDescription: nil).render()
        XCTAssertTrue(rendered.contains("Identity     : (not assigned"))
        XCTAssertTrue(rendered.contains("migrate this account first"))
    }

    /// The sheet exists to be printed and stored next to the key, which only works if it
    /// is genuinely non-secret.
    func testSheetCarriesNoSecrets() {
        let rendered = sheet().lowercased()
        for forbidden in ["password:", "pin:", "backup key:", "secret"] {
            XCTAssertFalse(rendered.contains(forbidden), "recovery sheet must not contain \(forbidden)")
        }
        XCTAssertTrue(rendered.contains("no passwords"))
    }

    /// Everything that feeds derivation has to be on the sheet, or it cannot do its job.
    func testSheetRecordsEveryDerivationInput() {
        let rendered = sheet()
        XCTAssertTrue(rendered.contains("personal-vault"), "account id")
        XCTAssertTrue(rendered.contains("Revision     : 3"), "revision")
        XCTAssertTrue(rendered.contains("Length       : 24"), "length")
        XCTAssertTrue(rendered.contains("vault"), "labels")
        XCTAssertTrue(rendered.contains("disk"), "labels")
    }

    func testCharacterClassesReflectThePolicy() {
        let rendered = sheet()
        XCTAssertTrue(rendered.contains("lower, upper, digits"))
        XCTAssertFalse(rendered.contains("symbols"), "symbols were disabled in this policy")
    }

    /// A local credential cannot be backed up at all, so the sheet says so outright.
    func testLocalCredentialCarriesTheIrrecoverableWarning() {
        XCTAssertTrue(sheet(kind: .local).contains("WARNING"))
        XCTAssertFalse(sheet(kind: .portable).contains("WARNING"))
    }

    func testMissingLabelsAreCalledOutRatherThanLeftBlank() {
        let rendered = sheet(labels: [])
        XCTAssertTrue(rendered.contains("none recorded yet"))
    }

    func testFileNameIsSafeForTheFilesystem() {
        let account = Account.fixture(id: "work/vault")
        let name = RecoverySheet(account: account, parameters: .v1, labels: [], deviceDescription: nil).suggestedFileName
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.hasSuffix(".txt"))
    }
}
