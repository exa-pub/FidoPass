import Foundation

public protocol Enrolling: Sendable {
    /// Creates a v2 account: one resident credential under `AccountFormat.v2RelyingPartyId`,
    /// `user.id` set to `identity`, and — for a local account — its record written to the
    /// large-blob store straight after. One touch. A portable account comes back without a
    /// record (`integrity == .recordMissing`) for `PortableEnrolling` to complete.
    func enroll(accountId: String,
                kind: AccountKind,
                identity: AccountIdentity,
                devicePath: String,
                askPIN: (@Sendable () -> String?)?,
                namesakePolicy: NamesakePolicy) throws -> AccountHandle

    /// Every FidoPass account on the key, of every format. PIN, no touch, one open.
    func enumerateAccounts(devicePath: String,
                           pin: String?) throws -> [AccountHandle]

    /// Deletes the credential and, for a v2 account, its record. PIN, no touch.
    func deleteAccount(_ handle: AccountHandle, pin: String?) throws

    /// Writes a v2 account's record — its kind and, for a portable account, the mask the
    /// handle carries — to the large-blob store. PIN, no touch.
    func writeRecord(for handle: AccountHandle,
                     pinProvider: (@Sendable () -> String?)?) throws
}
