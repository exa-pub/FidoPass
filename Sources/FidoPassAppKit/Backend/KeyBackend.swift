@preconcurrency import FidoPassCore
import Foundation

/// Everything the app layer asks of an authenticator, as one protocol.
///
/// The stores talk to this instead of `FidoPassCore` so they can be tested on a machine
/// with no key attached — CI never has one. It is also the single place where a blocking
/// libfido2 call is allowed to be started from.
protocol KeyBackend: Sendable {
    func listDevices() throws -> [FidoDevice]
    func status(devicePath: String) throws -> DeviceStatus
    /// Wide read of what the key says about itself. Opens the device; no PIN, no touch.
    func inspect(devicePath: String) throws -> AuthenticatorInfo
    /// Every resident credential on the key, of every relying party. PIN, no touch.
    func inventory(devicePath: String, pin: String) throws -> CredentialInventory
    func enumerateAccounts(kind: AccountKind, devicePath: String, pin: String) throws -> [Account]
    func enroll(accountId: String,
                kind: AccountKind,
                devicePath: String,
                askPIN: @escaping () -> String?) throws -> Account
    func enrollPortable(accountId: String,
                        devicePath: String,
                        askPIN: @escaping () -> String?,
                        importedKeyB64: String?,
                        onStep: @escaping (PortableEnrollmentStep) -> Void) throws -> (Account, String?)
    func generatePassword(account: Account,
                          label: String,
                          pinProvider: @escaping () -> String?) throws -> String
    func exportImportedKey(_ account: Account,
                           pinProvider: @escaping () -> String?) throws -> String
    func deriveEncryptionKey(account: Account,
                             label: String,
                             pinProvider: @escaping () -> String?) throws -> EncryptionKey
    func deleteAccount(_ account: Account, pin: String) throws
    func setInitialPIN(devicePath: String, newPIN: String) throws
    func changePIN(devicePath: String, oldPIN: String, newPIN: String) throws
    func resetDevice(devicePath: String, expectedAAGUID: String?) throws
    // Authenticator settings. All need the PIN, none needs a touch.
    func toggleAlwaysUV(devicePath: String, pin: String) throws -> Bool
    func setMinimumPINLength(devicePath: String, length: Int, pin: String) throws
    func forcePINChange(devicePath: String, pin: String) throws
    func enableEnterpriseAttestation(devicePath: String, pin: String) throws
}
