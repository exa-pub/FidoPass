import XCTest
@testable import FidoPassApp
import FidoPassCore
import TestSupport

/// The "last copied" indicator used to be a bare `Date?` on the view model. It survived
/// account switches, claimed copies that belonged to a different account, and advertised a
/// clipboard countdown that nothing ever read.
final class CopyReceiptTests: XCTestCase {

    private let copiedAt = Date(timeIntervalSince1970: 1_000_000)

    private func receipt(accountId: String = "vault",
                         devicePath: String? = "/dev/one",
                         clearsAfter: TimeInterval? = 45) -> AccountsViewModel.CopyReceipt {
        AccountsViewModel.CopyReceipt(accountId: accountId,
                                      devicePath: devicePath,
                                      item: .password,
                                      copiedAt: copiedAt,
                                      clearsAt: clearsAfter.map { copiedAt.addingTimeInterval($0) })
    }

    func testReceiptBelongsOnlyToItsOwnAccount() {
        let subject = receipt()
        XCTAssertTrue(subject.belongs(to: Account.fixture(id: "vault", devicePath: "/dev/one")))
        XCTAssertFalse(subject.belongs(to: Account.fixture(id: "other", devicePath: "/dev/one")))
    }

    /// The same account id on a second key is a backup, not the same account — a copy made
    /// on one key must not be reported on the other.
    func testReceiptIsScopedToTheDeviceToo() {
        XCTAssertFalse(receipt().belongs(to: Account.fixture(id: "vault", devicePath: "/dev/two")))
    }

    func testCountdownCountsDown() {
        let subject = receipt(clearsAfter: 45)
        XCTAssertEqual(subject.secondsUntilClear(at: copiedAt), 45)
        XCTAssertEqual(subject.secondsUntilClear(at: copiedAt.addingTimeInterval(30)), 15)
        XCTAssertEqual(subject.secondsUntilClear(at: copiedAt.addingTimeInterval(44.2)), 1)
    }

    /// Past the deadline the UI must say "cleared" rather than show a negative countdown.
    func testCountdownEndsRatherThanGoingNegative() {
        let subject = receipt(clearsAfter: 45)
        XCTAssertNil(subject.secondsUntilClear(at: copiedAt.addingTimeInterval(45)))
        XCTAssertNil(subject.secondsUntilClear(at: copiedAt.addingTimeInterval(600)))
    }

    func testReceiptWithoutDeadlineReportsNoCountdown() {
        XCTAssertNil(receipt(clearsAfter: nil).secondsUntilClear(at: copiedAt))
    }

    func testItemWordingDistinguishesPasswordFromBackupKey() {
        XCTAssertEqual(AccountsViewModel.CopyReceipt.Item.password.noun, "Password")
        XCTAssertEqual(AccountsViewModel.CopyReceipt.Item.backupKey.noun, "Backup key")
    }

    /// Relative text has to be a function of an explicit reference instant; deriving it from
    /// `Date()` inside a view body is what made the label freeze at its first value.
    func testRelativeTimeUsesTheSuppliedReference() {
        let later = copiedAt.addingTimeInterval(3600)
        let oneHour = ContentView.relativeTime(from: copiedAt, relativeTo: later)
        let now = ContentView.relativeTime(from: copiedAt, relativeTo: copiedAt)
        XCTAssertNotEqual(oneHour, now, "the same date must render differently against different references")
    }

    @MainActor
    func testSwitchingAccountsDropsTheReceipt() {
        let viewModel = AccountsViewModel(core: FidoPassCore(deviceLister: MockDeviceLister(),
                                                             enrollmentService: MockEnrollmentService(),
                                                             portableEnrollmentService: MockPortableEnrollmentService(),
                                                             secretDerivationService: MockSecretDerivationService(),
                                                             passwordGenerator: MockPasswordGenerator()),
                                          enableDeviceMonitors: false)
        viewModel.selected = Account.fixture(id: "vault")
        viewModel.copyReceipt = receipt()
        XCTAssertNotNil(viewModel.copyReceipt)

        viewModel.selected = Account.fixture(id: "other")
        XCTAssertNil(viewModel.copyReceipt, "a receipt must not follow the user to another account")
    }
}
