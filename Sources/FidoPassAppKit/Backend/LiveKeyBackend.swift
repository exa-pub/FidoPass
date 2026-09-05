import FidoPassCore
import Foundation

/// The real thing. Every method here blocks on the authenticator, so nothing may call it
/// from the main actor — `KeyWorker` is the only permitted caller.
struct LiveKeyBackend: KeyBackend {
    let core: FidoPassCore

    var messages: MessageSealing { core.messages }

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

    func enumerateAccounts(devicePath: String, pin: String) throws -> [AccountHandle] {
        try core.enumerateAccounts(devicePath: devicePath, pin: pin)
    }

    func enroll(accountId: String,
                kind: AccountKind,
                identity: AccountIdentity,
                devicePath: String,
                askPIN: @escaping @Sendable () -> String?) throws -> AccountHandle {
        try core.enroll(accountId: accountId, kind: kind, identity: identity, devicePath: devicePath, askPIN: askPIN)
    }

    func enrollPortable(accountId: String,
                        identity: AccountIdentity,
                        devicePath: String,
                        askPIN: @escaping @Sendable () -> String?,
                        imported: PortableBackup?,
                        onStep: @escaping @Sendable (PortableEnrollmentStep) -> Void) throws -> (AccountHandle, PortableBackup?) {
        try core.enrollPortable(accountId: accountId,
                                identity: identity,
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

    func migrate(_ old: AccountHandle,
                 identity: AccountIdentity,
                 askPIN: @escaping @Sendable () -> String?,
                 onStep: @escaping @Sendable (MigrationStep) -> Void) throws -> AccountHandle {
        try core.migrate(old, identity: identity, askPIN: askPIN, onStep: onStep)
    }

    func finishMigration(old: AccountHandle,
                         copy: AccountHandle,
                         askPIN: @escaping @Sendable () -> String?,
                         onStep: @escaping @Sendable (MigrationStep) -> Void) throws -> AccountHandle {
        try core.finishMigration(old: old, copy: copy, askPIN: askPIN, onStep: onStep)
    }

    func discardMigrationCopy(_ copy: AccountHandle, pin: String) throws {
        try core.discardMigrationCopy(copy, pin: pin)
    }

    func deriveMessageKey(_ handle: AccountHandle,
                          nonce: Data,
                          pinProvider: @escaping @Sendable () -> String?) throws -> MessageKey {
        try core.deriveMessageKey(handle, nonce: nonce, pinProvider: pinProvider)
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

    func setAlwaysUV(enabled: Bool, devicePath: String, pin: String) throws -> AlwaysUVChange {
        try core.setAlwaysUV(enabled: enabled, devicePath: devicePath, pin: pin)
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
