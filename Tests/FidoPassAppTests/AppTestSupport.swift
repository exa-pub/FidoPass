import CryptoKit
import Foundation
import XCTest
import FidoPassCore
import TestSupport
@testable import FidoPassAppKit

/// The condition guards entry and release; one release opens the gate permanently.
final class BlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var isOpen = false

    var hasEntered: Bool { condition.withLock { entered } }

    func wait() {
        condition.lock()
        defer { condition.unlock() }
        entered = true
        while !isOpen { condition.wait() }
    }

    func open() {
        condition.lock()
        defer { condition.unlock() }
        isOpen = true
        condition.broadcast()
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
    /// The master key every fresh portable enrolment and every export answers with. The
    /// identity of a backup is the account's own — the one the form chose, none for a v1
    /// account.
    var backupValue = PortableBackup(masterKey: Data(repeating: 0x42, count: 32),
                                     identity: AccountIdentity(hex: "42424242424242424242424242424242"))!
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
    private(set) var enrollCalls: [(accountId: String, kind: AccountKind, identity: AccountIdentity, imported: PortableBackup?)] = []
    private(set) var deleteCalls: [String] = []
    private(set) var exportCalls: [String] = []
    private(set) var migrateCalls: [(accountId: String, identity: AccountIdentity)] = []
    private(set) var finishCalls: [String] = []
    private(set) var discardCalls: [String] = []
    var migrateError: Error?
    /// When set, a migration stops right after creating the copy and throws — the state an
    /// unplugged key leaves behind.
    var migrationLeavesCopy = false
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
                                                        supportsLargeBlobs: true,
                                                        remainingResidentKeys: 20,
                                                        aaguid: aaguid)
    }

    func enumerateAccounts(devicePath: String, pin: String) throws -> [AccountHandle] {
        enumerateGate?.wait()
        enumerateCallCount += 1
        if let enumerateError { throw enumerateError }
        guard pins[devicePath] == pin else { throw Self.wrongPin }
        return (accountsByPath[devicePath] ?? []).map { AccountHandle(account: $0, devicePath: devicePath) }
    }

    func enroll(accountId: String, kind: AccountKind, identity: AccountIdentity, devicePath: String, askPIN: @escaping @Sendable () -> String?) throws -> AccountHandle {
        enrollCalls.append((accountId, kind, identity, nil))
        let account = Account.v2Fixture(id: accountId, kind: kind, identity: identity)
        accountsByPath[devicePath, default: []].append(account)
        return AccountHandle(account: account, devicePath: devicePath)
    }

    func enrollPortable(accountId: String,
                        identity: AccountIdentity,
                        devicePath: String,
                        askPIN: @escaping @Sendable () -> String?,
                        imported: PortableBackup?,
                        onStep: @escaping @Sendable (PortableEnrollmentStep) -> Void) throws -> (AccountHandle, PortableBackup?) {
        enrollCalls.append((accountId, .portable, identity, imported))
        onStep(.creatingCredential)
        onStep(.derivingBackupKey)
        onStep(.savingRecord)
        // As the real service: the identity the form chose is the one on the key, and the
        // one a fresh backup carries.
        let account = Account.v2Fixture(id: accountId, kind: .portable, identity: identity)
        accountsByPath[devicePath, default: []].append(account)
        let generated = imported == nil ? PortableBackup(masterKey: backupValue.masterKey, identity: identity) : nil
        return (AccountHandle(account: account, devicePath: devicePath), generated)
    }

    func migrate(_ old: AccountHandle,
                 identity: AccountIdentity,
                 askPIN: @escaping @Sendable () -> String?,
                 onStep: @escaping @Sendable (MigrationStep) -> Void) throws -> AccountHandle {
        migrateCalls.append((old.id, identity))
        guard pins[old.devicePath] == askPIN() else { throw Self.wrongPin }
        onStep(.readingOldAccount)
        onStep(.creatingCredential)
        if migrationLeavesCopy {
            let copy = Account.v2Fixture(id: old.id, kind: .portable, credentialId: Data("copy-\(old.id)".utf8),
                                         identity: identity, integrity: .recordMissing)
            accountsByPath[old.devicePath, default: []].append(copy)
            throw MigrationError.copyRemains(name: old.id, reason: "unplugged")
        }
        if let migrateError { throw migrateError }
        onStep(.derivingNewComponent)
        onStep(.savingRecord)
        onStep(.verifying)
        onStep(.deletingOld)
        let migrated = Account.v2Fixture(id: old.id, kind: .portable, credentialId: Data("copy-\(old.id)".utf8),
                                         identity: identity, mask: old.account.mask)
        accountsByPath[old.devicePath]?.removeAll { $0 == old.account }
        accountsByPath[old.devicePath, default: []].append(migrated)
        return AccountHandle(account: migrated, devicePath: old.devicePath)
    }

    func finishMigration(old: AccountHandle,
                         copy: AccountHandle,
                         askPIN: @escaping @Sendable () -> String?,
                         onStep: @escaping @Sendable (MigrationStep) -> Void) throws -> AccountHandle {
        finishCalls.append(old.id)
        if let migrateError { throw migrateError }
        onStep(.readingOldAccount)
        onStep(.verifying)
        onStep(.deletingOld)
        var done = copy.account
        done.mask = old.account.mask
        done.integrity = .ok
        accountsByPath[old.devicePath]?.removeAll { $0 == old.account || $0 == copy.account }
        accountsByPath[old.devicePath, default: []].append(done)
        return AccountHandle(account: done, devicePath: old.devicePath)
    }

    func discardMigrationCopy(_ copy: AccountHandle, pin: String) throws {
        discardCalls.append(copy.id)
        guard pins[copy.devicePath] == pin else { throw Self.wrongPin }
        accountsByPath[copy.devicePath]?.removeAll { $0 == copy.account }
    }

    func generatePassword(_ handle: AccountHandle, label: String, pinProvider: @escaping @Sendable () -> String?) throws -> String {
        generateCalls.append((handle.id, label))
        return generatedPassword
    }

    func exportBackup(_ handle: AccountHandle, pinProvider: @escaping @Sendable () -> String?) throws -> PortableBackup {
        exportCalls.append(handle.id)
        // What the key answers: this account's identity, or none for a v1 one.
        return PortableBackup(masterKey: backupValue.masterKey, identity: handle.account.identity)!
    }

    /// Uses real Core message crypto with deterministic per-credential/nonce secrets.
    /// A fixed portable component lets account and backup recover the same master key.
    private static let cryptoCore: FidoPassCore = {
        let derivation = MockSecretDerivationService()
        derivation.deriveMessageSecretClosure = { handle, nonce, _ in
            Data(SHA256.hash(data: nonce + Data(handle.credentialIdB64.utf8)))
        }
        derivation.deriveFixedClosure = { _, _ in Data(repeating: 0x33, count: 32) }
        return FidoPassCore(deviceLister: MockDeviceLister(),
                            enrollmentService: MockEnrollmentService(),
                            portableEnrollmentService: MockPortableEnrollmentService(),
                            secretDerivationService: derivation)
    }()

    var messages: MessageSealing { Self.cryptoCore.messages }

    private(set) var deriveMessageKeyCalls: [(accountId: String, nonce: Data)] = []
    var deriveMessageKeyError: Error?
    /// When set, `deriveMessageKey` blocks until the gate is opened — the key waiting for a touch.
    var deriveMessageKeyGate: BlockingGate?

    func deriveMessageKey(_ handle: AccountHandle, nonce: Data, pinProvider: @escaping @Sendable () -> String?) throws -> MessageKey {
        deriveMessageKeyGate?.wait()
        deriveMessageKeyCalls.append((handle.id, nonce))
        if let deriveMessageKeyError { throw deriveMessageKeyError }
        return try Self.cryptoCore.deriveMessageKey(handle, nonce: nonce, pinProvider: nil)
    }

    /// The nonce every test message is sealed under, unless a test says otherwise.
    static let testNonce = Data(repeating: 0x5A, count: 32)

    /// What a sender would hold: the link for an account. Not counted as a touch — it stands
    /// for a link the user was given earlier.
    func encryptionKey(for handle: AccountHandle, nonce: Data = MockKeyBackend.testNonce) throws -> EncryptionKeyURL {
        try Self.cryptoCore.deriveMessageKey(handle, nonce: nonce, pinProvider: nil).url
    }

    /// A message someone sealed for an account, as it would arrive.
    func sealedMessage(_ text: String, for handle: AccountHandle, nonce: Data = MockKeyBackend.testNonce) throws -> SealedMessageURL {
        try messages.seal(text, for: try encryptionKey(for: handle, nonce: nonce))
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
    #if FIDOPASS_VIRTUAL_KEYS
    private(set) var virtualDevicesOpened = 0
    #endif
    private(set) var decryptorClosed = 0
    private(set) var quitRequested = 0
    private(set) var openedEncryptors: [(key: EncryptionKeyURL?, account: Account?)] = []
    private(set) var openedDecryptors: [MessageDecryptStore] = []
    private(set) var savedSheets: [RecoverySheet] = []

    func openPanel() { panelOpened += 1 }
    func closePanel() { panelClosed += 1 }
    func openManager() { managerOpened += 1 }
    func openPreferences() { preferencesOpened += 1 }
    #if FIDOPASS_VIRTUAL_KEYS
    func openVirtualDevices() { virtualDevicesOpened += 1 }
    #endif
    func openEncryptor(with key: EncryptionKeyURL?, issuedFor account: Account?) { openedEncryptors.append((key, account)) }
    func openDecryptor(_ store: MessageDecryptStore) { openedDecryptors.append(store) }
    func closeDecryptor() { decryptorClosed += 1 }
    func saveRecoverySheet(_ sheet: RecoverySheet) { savedSheets.append(sheet) }
    func quit() { quitRequested += 1 }
}

enum AppTestFactory {

    /// Retains cross-store reactions until AppTestCase tears down the test.
    @MainActor
    private static var retained: [AppContainer] = []
    @MainActor private static var domains: [String] = []

    @MainActor static func cleanUp() {
        for container in retained {
            container.panel.panelDidClose()
            container.manager.managerDidClose()
            container.devices.lockAll()
            container.clipboard.clearIfOwned()
        }
        retained.removeAll()
        for suite in domains { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        domains.removeAll()
    }

    @MainActor
    static func makeDefaults(suite: String = "AppTests-\(UUID().uuidString)") -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        domains.append(suite)
        return defaults
    }

    /// The whole object graph on a mock key, with its own preferences domain so tests never
    /// touch the developer's real settings.
    @MainActor
    static func makeContainer(backend: KeyBackend,
                              suite: String = "HUDTests-\(UUID().uuidString)") -> AppContainer {
        let defaults = makeDefaults(suite: suite)
        let preferences = Preferences(defaults: defaults)
        let labels = LabelStore(userDefaults: defaults)
        let container = AppContainer(backend: backend,
                                     router: RecordingWindowRouter(),
                                     preferences: preferences,
                                     labels: labels,
                                     clipboard: ClipboardService(pasteboard: MemoryPasteboard()),
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
            Account.portableFixture(id: "vault"),
            Account.fixture(id: "disk", kind: .local)
        ]
        let store = makeStore(backend: backend)
        await store.prepareForDisplay()
        store.pinDraft = "1234"
        await store.submitPin()
        return (store, backend, device)
    }

    /// Seeds history for the selected credential and updates the label row.
    @MainActor
    static func seedLabels(_ store: PanelStore, _ labels: [String]) {
        guard let target = store.labelTarget(for: store.selection) else {
            XCTFail("no account selected, so there is no history to seed")
            return
        }
        for label in labels {
            store.labels.use(label, in: target)
            store.labelEditor.adopt(label)
        }
    }
}

// Fixture references use the same synthetic credential IDs as AccountHandle.fixture.
extension AccountRef {
    init(accountId: String, devicePath: String) {
        self.init(accountId: accountId, devicePath: devicePath,
                  credentialId: Data(accountId.utf8).base64EncodedString())
    }
}
