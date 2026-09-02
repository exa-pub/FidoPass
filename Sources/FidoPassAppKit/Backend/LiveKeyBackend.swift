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

    func enumerateAccounts(kind: AccountKind, devicePath: String, pin: String) throws -> [AccountHandle] {
        try core.enumerateAccounts(kind: kind, devicePath: devicePath, pin: pin)
    }

    func enroll(accountId: String,
                kind: AccountKind,
                devicePath: String,
                askPIN: @escaping @Sendable () -> String?) throws -> AccountHandle {
        try core.enroll(accountId: accountId, kind: kind, devicePath: devicePath, askPIN: askPIN)
    }

    func enrollPortable(accountId: String,
                        devicePath: String,
                        askPIN: @escaping @Sendable () -> String?,
                        imported: PortableBackup?,
                        onStep: @escaping @Sendable (PortableEnrollmentStep) -> Void) throws -> (AccountHandle, PortableBackup?) {
        try core.enrollPortable(accountId: accountId,
                                devicePath: devicePath,
                                askPIN: askPIN,
                                imported: imported,
                                onStep: onStep)
    }

    // Every account derives with `.v1` until the key can store parameters per account.
    func generatePassword(_ handle: AccountHandle,
                          label: String,
                          pinProvider: @escaping @Sendable () -> String?) throws -> String {
        try core.generatePassword(handle, label: label, parameters: .v1, pinProvider: pinProvider)
    }

    func exportBackup(_ handle: AccountHandle,
                      pinProvider: @escaping @Sendable () -> String?) throws -> PortableBackup {
        try core.exportBackup(handle, pinProvider: pinProvider)
    }

    func assignIdentity(_ handle: AccountHandle, identity: AccountIdentity, pin: String) throws -> AccountHandle {
        try core.assignIdentity(handle, identity: identity, pinProvider: { pin })
    }

    func deriveEncryptionKey(_ handle: AccountHandle,
                             label: String,
                             pinProvider: @escaping @Sendable () -> String?) throws -> EncryptionKey {
        try core.deriveEncryptionKey(handle, label: label, parameters: .v1, pinProvider: pinProvider)
    }

    func deleteAccount(_ handle: AccountHandle, pin: String) throws {
        try core.deleteAccount(handle, pin: pin)
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
