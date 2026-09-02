import Foundation
import XCTest
import FidoPassCore
import TestSupport
@testable import FidoPassAppKit

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
class MockKeyBackend: KeyBackend, @unchecked Sendable {

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
    /// Counted, not just answered: "did anything open the key" is the assertion, and an
    /// opened key is one no other process can use.
    private(set) var statusCallCount = 0
    /// Counted for the same reason as `statusCallCount`: both open the key, and "did anything
    /// open it" is the assertion the manager's tests are about.
    private(set) var inspectCallCount = 0
    private(set) var inventoryCallCount = 0
    var infoByPath: [String: AuthenticatorInfo] = [:]
    var inventoryByPath: [String: CredentialInventory] = [:]
    var inspectError: Error?
    var inventoryError: Error?
    private(set) var generateCalls: [(accountId: String, label: String)] = []
    private(set) var enrollCalls: [(accountId: String, kind: AccountKind, imported: String?)] = []
    private(set) var deleteCalls: [String] = []
    private(set) var exportCalls: [String] = []
    private(set) var setInitialPINCalls: [(path: String, pin: String)] = []
    private(set) var changePINCalls: [(path: String, old: String, new: String)] = []
    private(set) var resetCalls: [String] = []
    var setInitialPINError: Error?
    var changePINError: Error?
    var resetError: Error?

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

    private(set) var configCalls: [String] = []
    var alwaysUVByPath: [String: Bool] = [:]
    var configError: Error?

    func toggleAlwaysUV(devicePath: String, pin: String) throws -> Bool {
        configCalls.append("toggleAlwaysUV")
        guard pins[devicePath] == pin else { throw MockKeyBackend.wrongPin }
        if let configError { throw configError }
        let flipped = !(alwaysUVByPath[devicePath] ?? false)
        alwaysUVByPath[devicePath] = flipped
        return flipped
    }

    func setMinimumPINLength(devicePath: String, length: Int, pin: String) throws {
        configCalls.append("setMinimumPINLength(\(length))")
        guard pins[devicePath] == pin else { throw MockKeyBackend.wrongPin }
        if let configError { throw configError }
    }

    func forcePINChange(devicePath: String, pin: String) throws {
        configCalls.append("forcePINChange")
        guard pins[devicePath] == pin else { throw MockKeyBackend.wrongPin }
        if let configError { throw configError }
    }

    func enableEnterpriseAttestation(devicePath: String, pin: String) throws {
        configCalls.append("enableEnterpriseAttestation")
        guard pins[devicePath] == pin else { throw MockKeyBackend.wrongPin }
        if let configError { throw configError }
    }

    func inspect(devicePath: String) throws -> AuthenticatorInfo {
        inspectCallCount += 1
        if let inspectError { throw inspectError }
        return infoByPath[devicePath] ?? MockKeyBackend.info()
    }

    func inventory(devicePath: String, pin: String) throws -> CredentialInventory {
        inventoryCallCount += 1
        guard pins[devicePath] == pin else { throw MockKeyBackend.wrongPin }
        if let inventoryError { throw inventoryError }
        return inventoryByPath[devicePath] ?? CredentialInventory(relyingParties: [],
                                                                  residentKeysUsed: 0,
                                                                  residentKeysRemaining: 100,
                                                                  largeBlobArrayBytes: nil)
    }

    static func info(supportsCredentialManagement: Bool = true,
                     options: [AuthenticatorInfo.Option] = [.init(name: "credMgmt", value: true),
                                                            .init(name: "authnrCfg", value: true),
                                                            .init(name: "alwaysUv", value: false),
                                                            .init(name: "setMinPINLength", value: true)]) -> AuthenticatorInfo {
        AuthenticatorInfo(isFIDO2: true,
                          ctapHIDProtocol: 2,
                          ctapHIDVersion: "5.7.4",
                          capabilities: ["cbor"],
                          supportsPIN: true,
                          supportsUV: false,
                          supportsCredentialManagement: supportsCredentialManagement,
                          supportsCredentialProtection: true,
                          supportsPermissions: true,
                          hasPIN: true,
                          hasUV: false,
                          pinRetriesRemaining: 8,
                          uvRetriesRemaining: nil,
                          versions: ["FIDO_2_1"],
                          extensions: ["hmac-secret"],
                          options: options,
                          aaguid: "ff4dac45ede84ec2acedcf66103f4335",
                          pinProtocols: [2, 1],
                          algorithms: [AuthenticatorInfo.Algorithm(cose: -7, type: "public-key")],
                          transports: ["usb"],
                          certifications: [],
                          firmwareVersion: 0x050704,
                          limits: AuthenticatorInfo.Limits(maxMessageSize: 1536,
                                                           maxCredentialCountInList: 8,
                                                           maxCredentialIdLength: 128,
                                                           maxCredentialBlobLength: 32,
                                                           maxLargeBlob: 4096,
                                                           maxRPIDsForMinPINLength: 1),
                          minPINLength: 4,
                          forcePINChange: false,
                          remainingResidentKeys: 92,
                          uvAttempts: nil,
                          uvModalities: [])
    }

    static func inventory(rpId: String = "example.org", count: Int = 1) -> CredentialInventory {
        let credentials = (0..<count).map { index in
            ResidentCredential(rpId: rpId,
                               credentialIdB64: "cred-\(rpId)-\(index)",
                               userIdHex: "0\(index)",
                               userIdUTF8: "user\(index)",
                               userName: .value("user\(index)"),
                               userDisplayName: "User \(index)",
                               coseAlgorithm: -7,
                               publicKeyB64: nil,
                               credentialProtection: .uvOptional,
                               hasLargeBlobKey: true)
        }
        return CredentialInventory(
            relyingParties: [CredentialInventory.RelyingParty(id: rpId, name: nil, idHashHex: "aa",
                                                              credentials: credentials)],
            residentKeysUsed: count,
            residentKeysRemaining: 100 - count,
            largeBlobArrayBytes: 1)
    }

    func status(devicePath: String) throws -> DeviceStatus {
        statusCallCount += 1
        return statusByPath[devicePath] ?? DeviceStatus(pinRetriesRemaining: 5,
                                                        hasPIN: true,
                                                        supportsHmacSecret: true,
                                                        remainingResidentKeys: 20,
                                                        aaguid: aaguid)
    }

    func enumerateAccounts(kind: AccountKind, devicePath: String, pin: String) throws -> [AccountHandle] {
        enumerateGate?.wait()
        enumerateCallCount += 1
        if let enumerateError { throw enumerateError }
        guard pins[devicePath] == pin else { throw Self.wrongPin }
        return (accountsByPath[devicePath] ?? [])
            .filter { $0.kind == kind }
            .map { AccountHandle(account: $0, devicePath: devicePath) }
    }

    func enroll(accountId: String, kind: AccountKind, devicePath: String, askPIN: @escaping @Sendable () -> String?) throws -> AccountHandle {
        enrollCalls.append((accountId, kind, nil))
        let account = Account.fixture(id: accountId, kind: kind)
        accountsByPath[devicePath, default: []].append(account)
        return AccountHandle(account: account, devicePath: devicePath)
    }

    func enrollPortable(accountId: String,
                        devicePath: String,
                        askPIN: @escaping @Sendable () -> String?,
                        importedKeyB64: String?,
                        onStep: @escaping @Sendable (PortableEnrollmentStep) -> Void) throws -> (AccountHandle, String?) {
        enrollCalls.append((accountId, .portable, importedKeyB64))
        onStep(.creatingCredential)
        onStep(.derivingBackupKey)
        let account = Account.fixture(id: accountId, kind: .portable)
        accountsByPath[devicePath, default: []].append(account)
        return (AccountHandle(account: account, devicePath: devicePath), importedKeyB64 == nil ? backupKeyValue : nil)
    }

    func generatePassword(_ handle: AccountHandle, label: String, pinProvider: @escaping @Sendable () -> String?) throws -> String {
        generateCalls.append((handle.id, label))
        return generatedPassword
    }

    func exportImportedKey(_ handle: AccountHandle, pinProvider: @escaping @Sendable () -> String?) throws -> String {
        exportCalls.append(handle.id)
        return backupKeyValue
    }

    /// `EncryptionKey` is only constructible inside the core, so the mock borrows a core
    /// wired to a stub derivation service rather than faking the type — and the same core's
    /// cipher, so what it seals can be opened.
    private static let cryptoCore: FidoPassCore = {
        let derivation = MockSecretDerivationService()
        derivation.deriveSecretClosure = { _, _, _, _ in Data(repeating: 0x11, count: 32) }
        return FidoPassCore(deviceLister: MockDeviceLister(),
                            enrollmentService: MockEnrollmentService(),
                            portableEnrollmentService: MockPortableEnrollmentService(),
                            secretDerivationService: derivation)
    }()

    var cipher: SecretCipher { Self.cryptoCore.cipher }

    func deriveEncryptionKey(_ handle: AccountHandle, label: String, pinProvider: @escaping @Sendable () -> String?) throws -> EncryptionKey {
        try Self.cryptoCore.deriveEncryptionKey(handle, label: label, parameters: .v1, pinProvider: nil)
    }

    func deleteAccount(_ handle: AccountHandle, pin: String) throws {
        deleteCalls.append(handle.id)
        accountsByPath[handle.devicePath, default: []].removeAll { $0.id == handle.id }
    }

    func setInitialPIN(devicePath: String, newPIN: String) throws {
        setInitialPINCalls.append((devicePath, newPIN))
        if let setInitialPINError { throw setInitialPINError }
        pins[devicePath] = newPIN
        statusByPath[devicePath] = DeviceStatus(pinRetriesRemaining: 8,
                                                hasPIN: true,
                                                supportsHmacSecret: true,
                                                remainingResidentKeys: 20)
    }

    func changePIN(devicePath: String, oldPIN: String, newPIN: String) throws {
        changePINCalls.append((devicePath, oldPIN, newPIN))
        if let changePINError { throw changePINError }
        guard pins[devicePath] == oldPIN else { throw Self.wrongPin }
        pins[devicePath] = newPIN
    }

    /// AAGUID the mock claims for every key, so a test can hand back a "different" one.
    var aaguid: String? = "aa" + String(repeating: "00", count: 15)

    func resetDevice(devicePath: String, expectedAAGUID: String?) throws {
        resetCalls.append(devicePath)
        if let resetError { throw resetError }
        if let expectedAAGUID, let actual = aaguid, actual != expectedAAGUID {
            throw FidoPassError.invalidState("This is a different security key from the one you started with. Nothing was erased.")
        }
        // A reset key is an empty key with no PIN — the state the bootstrap screen exists for.
        pins[devicePath] = nil
        accountsByPath[devicePath] = []
        statusByPath[devicePath] = DeviceStatus(pinRetriesRemaining: nil,
                                                hasPIN: false,
                                                supportsHmacSecret: true,
                                                remainingResidentKeys: 25)
    }
}

/// A window router that only remembers what it was asked.
@MainActor
final class RecordingWindowRouter: WindowRouter {
    private(set) var panelOpened = 0
    private(set) var panelClosed = 0
    private(set) var managerOpened = 0
    private(set) var preferencesOpened = 0
    private(set) var editorClosed = 0
    private(set) var quitRequested = 0
    private(set) var openedEditors: [CryptoEditorSession] = []
    private(set) var savedSheets: [RecoverySheet] = []

    func openPanel() { panelOpened += 1 }
    func closePanel() { panelClosed += 1 }
    func openManager() { managerOpened += 1 }
    func openPreferences() { preferencesOpened += 1 }
    func openEditor(_ session: CryptoEditorSession) { openedEditors.append(session) }
    func closeEditor() { editorClosed += 1 }
    func saveRecoverySheet(_ sheet: RecoverySheet) { savedSheets.append(sheet) }
    func quit() { quitRequested += 1 }
}

enum AppTestFactory {

    /// Containers built for tests, kept alive for the process.
    ///
    /// The container owns the cross-store reactions (a key going away closes the editor and
    /// drops the inventory) through closures that hold it weakly. A test that keeps only the
    /// panel store would otherwise lose those reactions the moment the container was
    /// collected — which in the app never happens, because `AppDelegate` holds it.
    @MainActor
    private static var retained: [AppContainer] = []

    /// The whole object graph on a mock key, with its own preferences domain so tests never
    /// touch the developer's real settings.
    @MainActor
    static func makeContainer(backend: MockKeyBackend,
                              suite: String = "HUDTests-\(UUID().uuidString)") -> AppContainer {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let preferences = Preferences(defaults: defaults)
        let labels = LabelStore(userDefaults: defaults,
                                ubiStore: InMemoryUbiquitousStore(),
                                notificationCenter: NotificationCenter())
        let container = AppContainer(backend: backend,
                                     router: RecordingWindowRouter(),
                                     preferences: preferences,
                                     labels: labels,
                                     emptyConfirmationDelay: .milliseconds(1),
                                     enableMonitors: false)
        retained.append(container)
        return container
    }

    /// The panel's store on a mock key.
    @MainActor
    static func makeStore(backend: MockKeyBackend,
                          suite: String = "HUDTests-\(UUID().uuidString)") -> PanelStore {
        makeContainer(backend: backend, suite: suite).panel
    }

    /// The container a panel store was built in — the way to the other windows' stores.
    @MainActor
    static func container(for store: PanelStore) -> AppContainer {
        guard let container = retained.first(where: { $0.panel === store }) else {
            preconditionFailure("the store was not built by this factory")
        }
        return container
    }

    @MainActor
    static func manager(for store: PanelStore) -> ManagerStore { container(for: store).manager }

    @MainActor
    static func reset(for store: PanelStore) -> ResetCoordinator { container(for: store).reset }

    /// The usual starting point: one key, unlocked, with two accounts on it.
    @MainActor
    static func unlockedStore(accounts: [Account]? = nil) async -> (PanelStore, MockKeyBackend, FidoDevice) {
        let backend = MockKeyBackend()
        let device = MockKeyBackend.device()
        backend.devices = [device]
        backend.pins[device.path] = "1234"
        backend.accountsByPath[device.path] = accounts ?? [
            Account.fixture(id: "vault", kind: .portable),
            Account.fixture(id: "disk", kind: .local)
        ]
        let store = makeStore(backend: backend)
        await store.prepareForDisplay()
        store.pinDraft = "1234"
        await store.submitPin()
        return (store, backend, device)
    }

    /// Seeds label history for the account the store is currently pointed at.
    ///
    /// Labels are per account now, so a test that wants chips has to say which account they
    /// belong to — there is no global list left to write into.
    @MainActor
    static func seedLabels(_ store: PanelStore, _ labels: [String]) {
        guard let target = store.labelTarget(for: store.selection) else {
            XCTFail("no account selected, so there is no history to seed")
            return
        }
        // As generation would: the history is written, and the label just used becomes the
        // one the row points at.
        for label in labels {
            store.labels.use(label, in: target)
            store.labelEditor.adopt(label)
        }
    }
}
