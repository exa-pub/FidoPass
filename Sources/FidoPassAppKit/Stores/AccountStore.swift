import FidoPassCore
import Foundation

/// Accounts read from the keys that are currently unlocked.
///
/// Nothing is cached across launches: account metadata lives on the authenticator, and the
/// only copy the app keeps is this in-memory one, for as long as the key stays unlocked.
@MainActor
final class AccountStore: ObservableObject {

    /// What the panel lists. An unfinished migration copy is not in here — see
    /// `migrationCopies` — so an account id names one row per key, as `AccountRef` assumes.
    @Published private(set) var accounts: [AccountHandle] = []
    /// v2 accounts that share a name and a key with a v1 portable account: the copies an
    /// interrupted migration left. Ordinary creation refuses a taken name under every
    /// relying party, so the pair can arise no other way. Kept apart from the list, and
    /// reached through the v1 account they belong to.
    @Published private(set) var migrationCopies: [AccountHandle] = []
    @Published private(set) var isLoading = false

    /// Read failures, per device path. Kept separate from a global error so one unreadable
    /// key never implies the others are broken too.
    @Published private(set) var readErrors: [String: PresentedError] = [:]

    private var lifetimes: [String: OperationLease] = [:]
    private var loading = OperationLease()
    var onAuthenticationFailure: ((String) -> Void)?

    private func lifetime(for path: String) -> OperationLease {
        if let token = lifetimes[path] { return token }
        let token = OperationLease()
        lifetimes[path] = token
        return token
    }

    private func run<T: Sendable>(path: String, _ body: @escaping @Sendable (KeyAccountBackend) throws -> T) async throws -> T {
        let token = lifetime(for: path)
        let provider = pinProviderFor(path)
        do {
            let value = try await worker.accounts(validity: token) { backend in
                guard provider?() != nil else { throw KeyLockedError() }
                return try body(backend)
            }
            try KeyOperationContext.check(token)
            return value
        } catch {
            try KeyOperationContext.check(token)
            if [.pinInvalid, .pinAuthInvalid, .pinBlocked, .pinAuthBlocked].contains(KeyFailurePolicy.status(of: error)) {
                onAuthenticationFailure?(path)
            }
            throw error
        }
    }

    private func mutation<T: Sendable>(path: String, _ body: @escaping @Sendable (KeyAccountBackend) throws -> T) async throws -> T {
        do { return try await run(path: path, body) }
        catch {
            guard !(error is CancellationError) else { throw error }
            if KeyFailurePolicy.allowsAuthenticatedRecovery(after: error), let pin = pinFor(path) {
                do {
                    let fresh = try await run(path: path) { try $0.enumerateAccounts(devicePath: path, pin: pin) }
                    let split = Self.split(fresh)
                    accounts.removeAll { $0.devicePath == path }
                    migrationCopies.removeAll { $0.devicePath == path }
                    accounts += split.visible
                    migrationCopies += split.copies
                } catch {
                    guard !(error is CancellationError), pinFor(path) != nil else { throw error }
                    readErrors[path] = PresentedError(error)
                }
            } else {
                readErrors[path] = PresentedError(error)
            }
            throw error
        }
    }

    private let worker: KeyWorker
    private let pinFor: (String) -> String?
    private let pinProviderFor: (String) -> (@Sendable () -> String?)?

    init(worker: KeyWorker,
         pin: @escaping (String) -> String?,
         pinProvider: @escaping (String) -> (@Sendable () -> String?)?) {
        self.worker = worker
        self.pinFor = pin
        self.pinProviderFor = pinProvider
    }

    /// Seals and opens messages — what the message windows need, and nothing else.
    var messages: MessageSealing { worker.backend.messages }

    func accounts(onDevice path: String) -> [AccountHandle] {
        accounts.filter { $0.devicePath == path }
    }

    func account(_ ref: AccountRef) -> AccountHandle? {
        accounts.first { ref.matches($0) }
    }

    /// The unfinished v2 copy of a v1 portable account, if one is on its key.
    func migrationCopy(for ref: AccountRef) -> AccountHandle? {
        migrationCopies.first { $0.devicePath == ref.devicePath && $0.id.utf8.elementsEqual(ref.accountId.utf8) }
    }

    // MARK: - Loading

    /// Re-reads accounts from every unlocked key. One read per key, every format at once.
    ///
    /// Failures stay attached to the key that caused them: unplugging one key while another
    /// stays connected is routine — hot-plug is exactly when this runs — and must not blank
    /// the whole list.
    func reload(unlockedPaths: [String]) async {
        loading.invalidate()
        let token = OperationLease()
        loading = token
        isLoading = true
        defer { if loading === token { isLoading = false } }

        var collected: [AccountHandle] = []
        var errors: [String: PresentedError] = [:]

        for path in unlockedPaths {
            guard let pin = pinFor(path) else { continue }
            do {
                collected += try await run(path: path) { try $0.enumerateAccounts(devicePath: path, pin: pin) }
            } catch {
                if error is CancellationError { continue }
                errors[path] = PresentedError(error)
            }
        }

        guard token.isValid, KeyOperationContext.lease?.isValid != false else { return }
        let split = Self.split(collected)
        accounts = split.visible.sorted { $0.id < $1.id }
        migrationCopies = split.copies
        readErrors = errors
    }

    /// Separates unfinished migration copies from the accounts to list.
    static func split(_ all: [AccountHandle]) -> (visible: [AccountHandle], copies: [AccountHandle]) {
        let legacy = all.filter { $0.account.needsMigration }
        let copies = all.filter { candidate in
            candidate.account.format == .v2
                && legacy.contains { $0.id == candidate.id && $0.devicePath == candidate.devicePath }
        }
        let visible = all.filter { handle in !copies.contains(handle) }
        return (visible, copies)
    }

    func drop(devicePath: String) {
        lifetimes.removeValue(forKey: devicePath)?.invalidate()
        loading.invalidate()
        isLoading = false
        accounts.removeAll { $0.devicePath == devicePath }
        migrationCopies.removeAll { $0.devicePath == devicePath }
        readErrors.removeValue(forKey: devicePath)
    }

    func dropAll() {
        for token in lifetimes.values { token.invalidate() }
        lifetimes.removeAll()
        loading.invalidate()
        isLoading = false
        accounts.removeAll()
        migrationCopies.removeAll()
        readErrors.removeAll()
    }

    // MARK: - Enrolment

    /// What to create. Import is not a third kind of account: it creates a portable one from
    /// an existing backup, under the same relying party, deriving the same passwords and
    /// showing the same identity as the account the backup came from.
    enum EnrollRequest: Equatable {
        case local
        case portable
        case `import`(PortableBackup)

        var kind: AccountKind {
            switch self {
            case .local: return .local
            case .portable, .import: return .portable
            }
        }
    }

    /// Creates an account on the key, with the identity the form chose.
    ///
    /// Portable is not just a flag: it costs a second touch and — when the material is fresh
    /// — produces a backup that the caller must show the user immediately. Returning it here
    /// rather than storing it keeps that value out of the store's memory a moment longer
    /// than necessary.
    func enroll(accountId: String,
                identity: AccountIdentity,
                request: EnrollRequest,
                devicePath: String,
                onStep: @escaping @Sendable (PortableEnrollmentStep) -> Void) async throws -> (AccountHandle, PortableBackup?) {
        guard let provider = pinProviderFor(devicePath) else { throw KeyLockedError() }

        let result: (AccountHandle, PortableBackup?)
        switch request {
        case .portable, .import:
            let imported: PortableBackup?
            if case .import(let backup) = request { imported = backup } else { imported = nil }
            result = try await mutation(path: devicePath) {
                try $0.enrollPortable(accountId: accountId,
                                      identity: identity,
                                      devicePath: devicePath,
                                      askPIN: provider,
                                      imported: imported,
                                      onStep: onStep)
            }
        case .local:
            let account = try await mutation(path: devicePath) {
                try $0.enroll(accountId: accountId, kind: .local, identity: identity, devicePath: devicePath, askPIN: provider)
            }
            result = (account, nil)
        }

        accounts.append(result.0)
        accounts.sort { $0.id < $1.id }
        return result
    }

    // MARK: - Migration

    /// Recreates a v1 portable account as v2. Four touches; the original is deleted only
    /// after the copy has been verified. The migrated account takes the original's place in
    /// the list.
    func migrate(_ handle: AccountHandle,
                 identity: AccountIdentity,
                 onStep: @escaping @Sendable (MigrationStep) -> Void) async throws -> AccountHandle {
        guard let provider = pinProviderFor(handle.devicePath) else { throw KeyLockedError() }
        let migrated = try await mutation(path: handle.devicePath) { try $0.migrate(handle, identity: identity, askPIN: provider, onStep: onStep) }
        replace(handle, with: migrated)
        return migrated
    }

    /// Finishes the migration whose copy is on the key. Two touches when the copy has its
    /// record, the whole migration again when it does not.
    func finishMigration(_ handle: AccountHandle,
                         onStep: @escaping @Sendable (MigrationStep) -> Void) async throws -> AccountHandle {
        guard let provider = pinProviderFor(handle.devicePath) else { throw KeyLockedError() }
        guard let copy = migrationCopy(for: AccountRef(handle)) else {
            throw FidoPassError.invalidState("There is no unfinished copy of “\(handle.id)” on this key")
        }
        let migrated = try await mutation(path: handle.devicePath) { try $0.finishMigration(old: handle, copy: copy, askPIN: provider, onStep: onStep) }
        replace(handle, with: migrated)
        return migrated
    }

    /// Deletes the unfinished copy of an account. The original stays. PIN, no touch.
    func discardMigrationCopy(of handle: AccountHandle) async throws {
        guard let pin = pinFor(handle.devicePath) else { throw KeyLockedError() }
        guard let copy = migrationCopy(for: AccountRef(handle)) else { return }
        try await mutation(path: handle.devicePath) { try $0.discardMigrationCopy(copy, pin: pin) }
        migrationCopies.removeAll { $0 == copy }
    }

    private func replace(_ old: AccountHandle, with new: AccountHandle) {
        migrationCopies.removeAll { $0.id == new.id && $0.devicePath == new.devicePath }
        accounts.removeAll { $0 == old }
        accounts.append(new)
        accounts.sort { $0.id < $1.id }
    }

    func delete(_ handle: AccountHandle) async throws {
        guard let pin = pinFor(handle.devicePath) else { throw KeyLockedError() }
        try await mutation(path: handle.devicePath) { try $0.deleteAccount(handle, pin: pin) }
        accounts.removeAll { $0 == handle }
    }

    // MARK: - Key material

    func exportBackup(for handle: AccountHandle) async throws -> PortableBackup {
        guard let provider = pinProviderFor(handle.devicePath) else { throw KeyLockedError() }
        return try await run(path: handle.devicePath) { try $0.exportBackup(handle, pinProvider: provider) }
    }

    /// The account's message key for a nonce. One touch.
    func deriveMessageKey(for handle: AccountHandle, nonce: Data) async throws -> MessageKey {
        guard let provider = pinProviderFor(handle.devicePath) else { throw KeyLockedError() }
        return try await run(path: handle.devicePath) { try $0.deriveMessageKey(handle, nonce: nonce, pinProvider: provider) }
    }

    /// The account on a key that a message is for, found by its locator.
    ///
    /// Nothing on the key is asked: the locators come from the identities already read. One
    /// argon2id per account, which is why this is async and runs off the main actor. A v1
    /// portable account has no identity, no locator, and cannot match.
    func accountMatching(locator: AccountLocator, nonce: Data, onDevice path: String) async throws -> AccountHandle? {
        let candidates = accounts(onDevice: path).filter { $0.account.identity != nil && $0.account.canDerive }
        let sealer = messages
        return try await MessageCryptoWorker.shared.run {
            try candidates.first { candidate in
                guard let identity = candidate.account.identity else { return false }
                return try sealer.locator(nonce: nonce, identity: identity) == locator
            }
        }
    }
}
