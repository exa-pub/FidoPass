@preconcurrency import FidoPassCore
import Foundation

/// Identity of an account inside one session.
///
/// The account id alone is not an identity: the same id legitimately lives on two keys —
/// that is what a portable backup looks like. The device path completes it, and is valid
/// only until the key is unplugged.
struct AccountRef: Hashable, Sendable {
    let accountId: String
    let devicePath: String

    init(accountId: String, devicePath: String) {
        self.accountId = accountId
        self.devicePath = devicePath
    }

    init?(_ account: Account) {
        guard let path = account.devicePath else { return nil }
        self.init(accountId: account.id, devicePath: path)
    }

    func matches(_ account: Account) -> Bool {
        account.id == accountId && account.devicePath == devicePath
    }
}

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

/// The real thing. Every method here blocks on the authenticator, so nothing may call it
/// from the main actor — `KeyWorker` is the only permitted caller.
struct LiveKeyBackend: KeyBackend, @unchecked Sendable {
    let core: FidoPassCore

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
                askPIN: @escaping () -> String?) throws -> Account {
        try core.enroll(accountId: accountId,
                        kind: kind,
                        requireUV: true,
                        devicePath: devicePath,
                        askPIN: askPIN)
    }

    func enrollPortable(accountId: String,
                        devicePath: String,
                        askPIN: @escaping () -> String?,
                        importedKeyB64: String?,
                        onStep: @escaping (PortableEnrollmentStep) -> Void) throws -> (Account, String?) {
        try core.enrollPortable(accountId: accountId,
                                requireUV: true,
                                devicePath: devicePath,
                                askPIN: askPIN,
                                importedKeyB64: importedKeyB64,
                                onStep: onStep)
    }

    func generatePassword(account: Account,
                          label: String,
                          pinProvider: @escaping () -> String?) throws -> String {
        try core.generatePassword(account: account,
                                  label: label,
                                  requireUV: true,
                                  pinProvider: pinProvider)
    }

    func exportImportedKey(_ account: Account,
                           pinProvider: @escaping () -> String?) throws -> String {
        try core.exportImportedKey(account, requireUV: true, pinProvider: pinProvider)
    }

    func deriveEncryptionKey(account: Account,
                             label: String,
                             pinProvider: @escaping () -> String?) throws -> EncryptionKey {
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

/// The one thread on which the authenticator is spoken to.
///
/// A security key is exclusive: opening it seizes the device, and two overlapping operations
/// mean one of them fails for a reason that has nothing to do with what the user did. That
/// could not happen while the panel was the only caller — a panel does one thing at a time —
/// but the manager window can now read a key while the panel is generating a password from
/// it, so the ordering has to be made explicit rather than left to the UI's shape.
///
/// A serial queue rather than an actor: the work is a blocking C call, and an actor that
/// awaited it would suspend and let the next caller straight in, which is precisely what
/// must not happen.
private final class KeyAccessQueue: @unchecked Sendable {
    static let shared = KeyAccessQueue()

    private let queue = DispatchQueue(label: "com.fidopass.keyAccess", qos: .userInitiated)

    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}

/// Runs backend work off the main actor, one operation at a time.
///
/// libfido2 calls block for as long as the user takes to touch the key — seconds, sometimes
/// tens of them. Wrapping them here keeps that fact in one place instead of scattering
/// `Task.detached` through the stores, and routing every one through `KeyAccessQueue` keeps
/// two windows from reaching for the same key at once.
struct KeyWorker: Sendable {
    let backend: KeyBackend

    init(backend: KeyBackend) {
        self.backend = backend
    }

    func run<T: Sendable>(_ body: @escaping @Sendable (KeyBackend) throws -> T) async throws -> T {
        let backend = self.backend
        return try await KeyAccessQueue.shared.run { try body(backend) }
    }
}
