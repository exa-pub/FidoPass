import Foundation

/// An account bound to its connected key. The path is valid only for this connection;
/// operations never fall back to the first available device.
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
