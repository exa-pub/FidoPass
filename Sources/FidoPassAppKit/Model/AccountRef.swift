import FidoPassCore
import Foundation

/// Identity of an account inside one session.
///
/// The account id alone is not an identity: the same id legitimately lives on two keys —
/// that is what a portable backup looks like. The device path completes it, and is valid
/// only until the key is unplugged. It is the light-weight locator the panel keeps in its
/// selection, its pending intent and its clipboard receipt; the account itself is looked
/// up in `AccountStore` when needed.
///
/// The other identity in the app is `LabelScope`, keyed by credential id: permanent, for
/// what is written to disk. This one is never written anywhere.
struct AccountRef: Hashable, Sendable {
    let accountId: String
    let devicePath: String

    init(accountId: String, devicePath: String) {
        self.accountId = accountId
        self.devicePath = devicePath
    }

    init(_ handle: AccountHandle) {
        self.init(accountId: handle.id, devicePath: handle.devicePath)
    }

    func matches(_ handle: AccountHandle) -> Bool {
        handle.id == accountId && handle.devicePath == devicePath
    }
}
