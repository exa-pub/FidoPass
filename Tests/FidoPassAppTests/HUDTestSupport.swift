import Foundation
import FidoPassCore
import TestSupport
@testable import FidoPassApp

/// Lets a test hold a backend call open, so mid-flight UI state can be observed.
///
/// One-shot: once opened it stays open. A plain semaphore deadlocked the suite, because
/// unlocking is immediately followed by a second enumeration for the account list.
final class BlockingGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var isOpen = false

    func wait() {
        lock.lock()
        let opened = isOpen
        lock.unlock()
        guard !opened else { return }
        semaphore.wait()
    }

    func open() {
        lock.lock()
        isOpen = true
        lock.unlock()
        semaphore.signal()
    }
}

/// A key that exists only in memory.
///
/// CI has no authenticator, so every store test runs against this. It is deliberately
/// picky about the PIN: "wrong PIN decrements the attempts the user is shown" is one of the
/// behaviours worth pinning down.
final class MockKeyBackend: KeyBackend, @unchecked Sendable {

    var devices: [FidoDevice] = []
    var pins: [String: String] = [:]
    var accountsByPath: [String: [Account]] = [:]
    var statusByPath: [String: DeviceStatus] = [:]
    var generatedPassword = "PASSWORD-from-key"
    var backupKeyValue = "BACKUP-KEY"
    var enumerateError: Error?
    var listDevicesError: Error?
    /// When set, `enumerateAccounts` blocks until the gate is opened.
    var enumerateGate: BlockingGate?
    /// Answers for successive `listDevices` calls; the last one repeats once exhausted.
    var listDevicesResults: [[FidoDevice]]?

    private(set) var enumerateCallCount = 0
    private(set) var generateCalls: [(accountId: String, label: String)] = []
    private(set) var enrollCalls: [(accountId: String, kind: AccountKind, imported: String?)] = []
    private(set) var deleteCalls: [String] = []
    private(set) var exportCalls: [String] = []

    static func device(path: String = "/dev/one",
                       product: String = "YubiKey 5",
                       vendorId: Int = 0x1050,
                       productId: Int = 0x0407) -> FidoDevice {
        FidoDevice(path: path, product: product, manufacturer: "Yubico", vendorId: vendorId, productId: productId)
    }

    static let wrongPin = FidoPassError.libfido2(operation: "getAssertion",
                                                 status: .pinInvalid,
                                                 message: "PIN invalid")

    private(set) var listDevicesCallCount = 0

    func listDevices() throws -> [FidoDevice] {
        listDevicesCallCount += 1
        if let listDevicesError { throw listDevicesError }
        guard var queue = listDevicesResults else { return devices }
        let next = queue.removeFirst()
        if !queue.isEmpty { listDevicesResults = queue }
        return next
    }

    func status(devicePath: String) throws -> DeviceStatus {
        statusByPath[devicePath] ?? DeviceStatus(pinRetriesRemaining: 5,
                                                 hasPIN: true,
                                                 supportsHmacSecret: true,
                                                 remainingResidentKeys: 20)
    }

    func enumerateAccounts(kind: AccountKind, devicePath: String, pin: String) throws -> [Account] {
        enumerateGate?.wait()
        enumerateCallCount += 1
        if let enumerateError { throw enumerateError }
        guard pins[devicePath] == pin else { throw Self.wrongPin }
        return (accountsByPath[devicePath] ?? []).filter { $0.kind == kind }
    }

    func enroll(accountId: String, kind: AccountKind, devicePath: String, askPIN: @escaping () -> String?) throws -> Account {
        enrollCalls.append((accountId, kind, nil))
        let account = Account.fixture(id: accountId, kind: kind, devicePath: devicePath)
        accountsByPath[devicePath, default: []].append(account)
        return account
    }

    func enrollPortable(accountId: String,
                        devicePath: String,
                        askPIN: @escaping () -> String?,
                        importedKeyB64: String?,
                        onStep: @escaping (PortableEnrollmentStep) -> Void) throws -> (Account, String?) {
        enrollCalls.append((accountId, .portable, importedKeyB64))
        onStep(.creatingCredential)
        onStep(.derivingBackupKey)
        let account = Account.fixture(id: accountId, kind: .portable, devicePath: devicePath)
        accountsByPath[devicePath, default: []].append(account)
        return (account, importedKeyB64 == nil ? backupKeyValue : nil)
    }

    func generatePassword(account: Account, label: String, pinProvider: @escaping () -> String?) throws -> String {
        generateCalls.append((account.id, label))
        return generatedPassword
    }

    func exportImportedKey(_ account: Account, pinProvider: @escaping () -> String?) throws -> String {
        exportCalls.append(account.id)
        return backupKeyValue
    }

    /// `EncryptionKey` is only constructible inside the core, so the mock borrows a core
    /// wired to a stub derivation service rather than faking the type.
    func deriveEncryptionKey(account: Account, label: String, pinProvider: @escaping () -> String?) throws -> EncryptionKey {
        let derivation = MockSecretDerivationService()
        derivation.deriveSecretClosure = { _, _, _, _ in Data(repeating: 0x11, count: 32) }
        let core = FidoPassCore(deviceLister: MockDeviceLister(),
                                enrollmentService: MockEnrollmentService(),
                                portableEnrollmentService: MockPortableEnrollmentService(),
                                secretDerivationService: derivation)
        return try core.deriveEncryptionKey(account: account, label: label, requireUV: true, pinProvider: nil)
    }

    func deleteAccount(_ account: Account, pin: String) throws {
        deleteCalls.append(account.id)
        accountsByPath[account.devicePath ?? "", default: []].removeAll { $0.id == account.id }
    }
}

enum HUDTestFactory {

    /// A store wired to a mock key, with its own preferences domain so tests never touch the
    /// developer's real settings.
    @MainActor
    static func makeStore(backend: MockKeyBackend,
                          suite: String = "HUDTests-\(UUID().uuidString)") -> HUDStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let preferences = Preferences(defaults: defaults)
        let labels = LabelStore(userDefaults: defaults,
                                ubiStore: NSUbiquitousKeyValueStore(),
                                notificationCenter: NotificationCenter())
        return HUDStore(backend: backend,
                        preferences: preferences,
                        labels: labels,
                        emptyConfirmationDelay: .milliseconds(1),
                        enableMonitors: false)
    }

    /// The usual starting point: one key, unlocked, with two accounts on it.
    @MainActor
    static func unlockedStore(accounts: [Account]? = nil) async -> (HUDStore, MockKeyBackend, FidoDevice) {
        let backend = MockKeyBackend()
        let device = MockKeyBackend.device()
        backend.devices = [device]
        backend.pins[device.path] = "1234"
        backend.accountsByPath[device.path] = accounts ?? [
            Account.fixture(id: "vault", kind: .portable, devicePath: device.path),
            Account.fixture(id: "disk", kind: .local, devicePath: device.path)
        ]
        let store = makeStore(backend: backend)
        await store.prepareForDisplay()
        store.pinDraft = "1234"
        await store.submitPin()
        return (store, backend, device)
    }
}
