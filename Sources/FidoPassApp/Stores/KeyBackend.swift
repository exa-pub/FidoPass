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
}

/// Runs backend work off the main actor.
///
/// libfido2 calls block for as long as the user takes to touch the key — seconds, sometimes
/// tens of them. Wrapping them here keeps that fact in one place instead of scattering
/// `Task.detached` through the stores.
struct KeyWorker: Sendable {
    let backend: KeyBackend

    init(backend: KeyBackend) {
        self.backend = backend
    }

    func run<T: Sendable>(_ body: @escaping @Sendable (KeyBackend) throws -> T) async throws -> T {
        let backend = self.backend
        return try await Task.detached(priority: .userInitiated) {
            try body(backend)
        }.value
    }
}
