import FidoPassCore
import Foundation

/// What the app layer asks of an authenticator, in three facets.
///
/// The stores talk to these instead of `FidoPassCore` so they can be tested on a machine
/// with no key attached — CI never has one. Split by consumer: the manager reads, the
/// panel works with accounts, the settings and reset flows administer the key itself. A
/// store names the facet it needs, and a test can substitute just that.
///
/// Every method here blocks on the authenticator; `KeyWorker` is the only permitted caller.

/// Listing and reading keys. Nothing here writes, nothing needs a touch.
protocol KeyDeviceBackend: Sendable {
    func listDevices() throws -> [FidoDevice]
    func status(devicePath: String) throws -> DeviceStatus
    /// Wide read of what the key says about itself. Opens the device; no PIN, no touch.
    func inspect(devicePath: String) throws -> AuthenticatorInfo
    /// Every resident credential on the key, of every relying party. PIN, no touch.
    func inventory(devicePath: String, pin: String) throws -> CredentialInventory
}

/// FidoPass accounts on a key: enumerating, creating, deriving from, deleting.
protocol KeyAccountBackend: Sendable {
    func enumerateAccounts(kind: AccountKind, devicePath: String, pin: String) throws -> [AccountHandle]
    func enroll(accountId: String,
                kind: AccountKind,
                devicePath: String,
                askPIN: @escaping @Sendable () -> String?) throws -> AccountHandle
    func enrollPortable(accountId: String,
                        devicePath: String,
                        askPIN: @escaping @Sendable () -> String?,
                        imported: PortableBackup?,
                        onStep: @escaping @Sendable (PortableEnrollmentStep) -> Void) throws -> (AccountHandle, PortableBackup?)
    func generatePassword(_ handle: AccountHandle,
                          label: String,
                          pinProvider: @escaping @Sendable () -> String?) throws -> String
    /// The account's master key and identity. One touch.
    func exportBackup(_ handle: AccountHandle,
                      pinProvider: @escaping @Sendable () -> String?) throws -> PortableBackup
    /// Writes an identity onto a portable account from before identities. PIN, no touch.
    func assignIdentity(_ handle: AccountHandle, identity: AccountIdentity, pin: String) throws -> AccountHandle
    func deriveEncryptionKey(_ handle: AccountHandle,
                             label: String,
                             pinProvider: @escaping @Sendable () -> String?) throws -> EncryptionKey
    func deleteAccount(_ handle: AccountHandle, pin: String) throws
    /// Seals and opens text under a derived key. Pure computation — no device — which is why
    /// the editor gets this rather than the whole backend.
    var cipher: SecretCipher { get }
}

/// The key itself: its PIN, its settings, its erasure.
protocol KeyAdminBackend: Sendable {
    func setInitialPIN(devicePath: String, newPIN: String) throws
    func changePIN(devicePath: String, oldPIN: String, newPIN: String) throws
    func resetDevice(devicePath: String, expectedAAGUID: String?) throws
    // Authenticator settings. All need the PIN, none needs a touch.
    func toggleAlwaysUV(devicePath: String, pin: String) throws -> Bool
    func setMinimumPINLength(devicePath: String, length: Int, pin: String) throws
    func forcePINChange(devicePath: String, pin: String) throws
    func enableEnterpriseAttestation(devicePath: String, pin: String) throws
}

typealias KeyBackend = KeyDeviceBackend & KeyAccountBackend & KeyAdminBackend
