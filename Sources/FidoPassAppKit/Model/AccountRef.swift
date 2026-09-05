import FidoPassCore
import Foundation

/// Session reference: credential ID plus current device path; accountId is display text.
/// Never persisted. LabelScope identifies persistent history by credential ID alone.
struct AccountRef: Hashable, Sendable {
    let accountId: String
    let devicePath: String
    let credentialId: String

    init(accountId: String, devicePath: String, credentialId: String) {
        self.accountId = accountId
        self.devicePath = devicePath
        self.credentialId = credentialId
    }

    init(_ handle: AccountHandle) {
        self.init(accountId: handle.id, devicePath: handle.devicePath, credentialId: handle.credentialIdB64)
    }

    func matches(_ handle: AccountHandle) -> Bool {
        handle.credentialIdB64 == credentialId && handle.devicePath == devicePath
    }
}
