import XCTest
@testable import FidoPassAppKit
import FidoPassCore
import TestSupport

/// The "on the clipboard" indicator used to be a bare `Date?`. It survived account switches,
/// claimed copies that belonged to a different account, and advertised a countdown that
/// nothing ever read.
final class ClipboardReceiptTests: XCTestCase {

    private let copiedAt = Date(timeIntervalSince1970: 1_000_000)

    private func receipt(accountId: String = "vault",
                         devicePath: String = "/dev/one",
                         clearsAfter: TimeInterval? = 45) -> ClipboardReceipt {
        ClipboardReceipt(ref: AccountRef(accountId: accountId, devicePath: devicePath),
                         item: .password,
                         copiedAt: copiedAt,
                         clearsAt: clearsAfter.map { copiedAt.addingTimeInterval($0) })
    }

    func testReceiptBelongsOnlyToItsOwnAccount() {
        let subject = receipt()
        XCTAssertTrue(subject.belongs(to: AccountHandle.fixture(id: "vault", devicePath: "/dev/one")))
        XCTAssertFalse(subject.belongs(to: AccountHandle.fixture(id: "other", devicePath: "/dev/one")))
    }

    /// The same account id on a second key is a backup, not the same account — a copy made
    /// on one key must not be reported on the other.
    func testReceiptIsScopedToTheDeviceToo() {
        XCTAssertFalse(receipt().belongs(to: AccountHandle.fixture(id: "vault", devicePath: "/dev/two")))
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

    /// A backup key is not a password, and the wording that accompanies it must never let it
    /// be mistaken for one.
    func testItemWordingDistinguishesPasswordFromBackupKey() {
        XCTAssertEqual(ClipboardReceipt.Item.password.noun, "Password")
        XCTAssertEqual(ClipboardReceipt.Item.backupKey.noun, "Backup key")
    }
}
