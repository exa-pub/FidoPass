import FidoPassCore
import Foundation

/// The real thing. Every method here blocks on the authenticator, so nothing may call it
/// from the main actor — `KeyWorker` is the only permitted caller.
struct LiveKeyBackend: KeyBackend {
    let core: FidoPassCore

    var cipher: SecretCipher { core.cipher }

    init(core: FidoPassCore = .shared) {
        self.core = core
    }

    func listDevices() throws -> [FidoDevice] {
        try core.listDevices()
    }

    func status(devicePath: String) throws -> DeviceStatus {
        try core.status(devicePath: devicePath)
    }

    func inspect(devicePath: String) throws -> AuthenticatorInfo {
        try core.inspect(devicePath: devicePath)
    }

    func inventory(devicePath: String, pin: String) throws -> CredentialInventory {
        try core.inventory(devicePath: devicePath, pin: pin)
    }

    func enumerateAccounts(kind: AccountKind, devicePath: String, pin: String) throws -> [Account] {
        try core.enumerateAccounts(kind: kind, devicePath: devicePath, pin: pin)
    }

    func enroll(accountId: String,
                kind: AccountKind,
                devicePath: String,
                askPIN: @escaping @Sendable () -> String?) throws -> Account {
        try core.enroll(accountId: accountId,
                        kind: kind,
                        requireUV: true,
                        devicePath: devicePath,
                        askPIN: askPIN)
    }

    func enrollPortable(accountId: String,
                        devicePath: String,
                        askPIN: @escaping @Sendable () -> String?,
                        importedKeyB64: String?,
                        onStep: @escaping @Sendable (PortableEnrollmentStep) -> Void) throws -> (Account, String?) {
        try core.enrollPortable(accountId: accountId,
                                requireUV: true,
                                devicePath: devicePath,
                                askPIN: askPIN,
                                importedKeyB64: importedKeyB64,
                                onStep: onStep)
    }

    func generatePassword(account: Account,
                          label: String,
                          pinProvider: @escaping @Sendable () -> String?) throws -> String {
        try core.generatePassword(account: account,
                                  label: label,
                                  requireUV: true,
                                  pinProvider: pinProvider)
    }

    func exportImportedKey(_ account: Account,
                           pinProvider: @escaping @Sendable () -> String?) throws -> String {
        try core.exportImportedKey(account, requireUV: true, pinProvider: pinProvider)
    }

    func deriveEncryptionKey(account: Account,
                             label: String,
                             pinProvider: @escaping @Sendable () -> String?) throws -> EncryptionKey {
        try core.deriveEncryptionKey(account: account,
                                     label: label,
                                     requireUV: true,
                                     pinProvider: pinProvider)
    }

    func deleteAccount(_ account: Account, pin: String) throws {
        try core.deleteAccount(account, pin: pin)
    }

    func setInitialPIN(devicePath: String, newPIN: String) throws {
        try core.setInitialPIN(devicePath: devicePath, newPIN: newPIN)
    }

    func changePIN(devicePath: String, oldPIN: String, newPIN: String) throws {
        try core.changePIN(devicePath: devicePath, oldPIN: oldPIN, newPIN: newPIN)
    }

    func toggleAlwaysUV(devicePath: String, pin: String) throws -> Bool {
        try core.toggleAlwaysUV(devicePath: devicePath, pin: pin)
    }

    func setMinimumPINLength(devicePath: String, length: Int, pin: String) throws {
        try core.setMinimumPINLength(devicePath: devicePath, length: length, pin: pin)
    }

    func forcePINChange(devicePath: String, pin: String) throws {
        try core.forcePINChange(devicePath: devicePath, pin: pin)
    }

    func enableEnterpriseAttestation(devicePath: String, pin: String) throws {
        try core.enableEnterpriseAttestation(devicePath: devicePath, pin: pin)
    }

    func resetDevice(devicePath: String, expectedAAGUID: String?) throws {
        // The deadline lives here rather than at the call site: a reset that nobody confirms
        // blocks this worker thread until the process dies, and no screen should be able to
        // opt out of that limit by forgetting an argument.
        try core.resetDevice(devicePath: devicePath,
                             expectedAAGUID: expectedAAGUID,
                             timeout: .seconds(35))
    }
}
