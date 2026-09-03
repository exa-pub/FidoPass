import Foundation

/// An account as read from a key that is plugged in right now.
///
/// The device path is a session handle: it changes on every reconnect and is never stored.
/// Every core operation that talks to the key takes one of these, so there is no way to ask
/// for a password, a backup key or a deletion without saying which connected key — and no
/// "first device" fallback that would open a key nobody asked for.
///
/// The same account id legitimately lives on two keys — that is what a portable backup looks
/// like — so two handles with the same account and different paths are two different things.
public struct AccountHandle: Hashable, Sendable {
    public var account: Account
    public let devicePath: String

    public init(account: Account, devicePath: String) {
        self.account = account
        self.devicePath = devicePath
    }

    public var id: String { account.id }
    public var kind: AccountKind { account.kind }
    public var credentialIdB64: String { account.credentialIdB64 }
}
