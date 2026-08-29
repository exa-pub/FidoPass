import XCTest
@testable import FidoPassApp
import FidoPassCore
import TestSupport

final class RecoverySheetTests: XCTestCase {

    private func sheet(kind: AccountKind = .local,
                       labels: [String] = ["vault", "disk"]) -> String {
        var account = Account.fixture(id: "personal-vault", kind: kind, revision: 3)
        account.policy = PasswordPolicy(length: 24, useSymbols: false)
        return RecoverySheet(account: account,
                             labels: labels,
                             deviceDescription: "Yubico YubiKey Bio — VID 1050 PID 0402")
            .render()
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
        var account = Account.fixture(id: "work/vault")
        account.policy = PasswordPolicy()
        let name = RecoverySheet(account: account, labels: [], deviceDescription: nil).suggestedFileName
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.hasSuffix(".txt"))
    }
}
