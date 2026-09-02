import FidoPassCore
import Foundation

/// A secret this app put on the clipboard, and whether it is still there.
///
/// Scoped to the account it was produced for: the same account id on a second key is a
/// backup, not the same account, so a copy made on one key must never be reported on the
/// other.
struct ClipboardReceipt: Equatable {
    enum Item: Equatable {
        case password
        case backupKey

        var noun: String {
            switch self {
            case .password:  return "Password"
            case .backupKey: return "Backup key"
            }
        }
    }

    let ref: AccountRef
    let item: Item
    let copiedAt: Date
    /// Nil once the clipboard no longer holds the value.
    var clearsAt: Date?

    func belongs(to handle: AccountHandle) -> Bool { ref.matches(handle) }

    /// Whole seconds left before the clipboard is wiped, or nil once it is gone.
    func secondsUntilClear(at now: Date) -> Int? {
        guard let clearsAt else { return nil }
        let remaining = clearsAt.timeIntervalSince(now)
        return remaining > 0 ? Int(remaining.rounded(.up)) : nil
    }
}
