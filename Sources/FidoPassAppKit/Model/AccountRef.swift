import FidoPassCore
import Foundation

/// Identity of an account inside one session.
///
/// The account id alone is not an identity: the same id legitimately lives on two keys —
/// that is what a portable backup looks like. The device path completes it, and is valid
/// only until the key is unplugged.
struct AccountRef: Hashable, Sendable {
    let accountId: String
    let devicePath: String

    init(accountId: String, devicePath: String) {
        self.accountId = accountId
        self.devicePath = devicePath
    }

    init?(_ account: Account) {
        guard let path = account.devicePath else { return nil }
        self.init(accountId: account.id, devicePath: path)
    }

    func matches(_ account: Account) -> Bool {
        account.id == accountId && account.devicePath == devicePath
    }
}
