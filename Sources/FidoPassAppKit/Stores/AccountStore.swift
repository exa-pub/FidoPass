@preconcurrency import FidoPassCore
import Foundation

/// Accounts read from the keys that are currently unlocked.
///
/// Nothing is cached across launches: account metadata lives on the authenticator, and the
/// only copy the app keeps is this in-memory one, for as long as the key stays unlocked.
@MainActor
final class AccountStore: ObservableObject {

    @Published private(set) var accounts: [Account] = []
    @Published private(set) var isLoading = false

    /// Read failures, per device path. Kept separate from a global error so one unreadable
    /// key never implies the others are broken too.
    @Published private(set) var readErrors: [String: String] = [:]

    private let worker: KeyWorker
    private let pinFor: (String) -> String?
    private let pinProviderFor: (String) -> (() -> String?)?

    init(backend: KeyBackend,
         pin: @escaping (String) -> String?,
         pinProvider: @escaping (String) -> (() -> String?)?) {
        self.worker = KeyWorker(backend: backend)
        self.pinFor = pin
        self.pinProviderFor = pinProvider
    }

    func accounts(onDevice path: String) -> [Account] {
        accounts.filter { $0.devicePath == path }
    }

    func account(_ ref: AccountRef) -> Account? {
        accounts.first { ref.matches($0) }
    }

    // MARK: - Loading

    /// Re-reads accounts from every unlocked key.
    ///
    /// Failures stay attached to the key that caused them: unplugging one key while another
    /// stays connected is routine — hot-plug is exactly when this runs — and must not blank
    /// the whole list.
    func reload(unlockedPaths: [String]) async {
        isLoading = true
        defer { isLoading = false }

        var collected: [Account] = []
        var errors: [String: String] = [:]

        for path in unlockedPaths {
            guard let pin = pinFor(path) else { continue }
            for kind in AccountKind.allCases {
                do {
                    collected += try await worker.run { try $0.enumerateAccounts(kind: kind, devicePath: path, pin: pin) }
                } catch {
                    // Keep the first failure per key: later kinds usually fail for the same
                    // underlying reason and would only overwrite it.
                    if errors[path] == nil {
                        errors[path] = FidoPassErrorPresenter.message(for: error).title
                    }
                }
            }
        }

        accounts = collected.sorted { $0.id < $1.id }
        readErrors = errors
    }

    func drop(devicePath: String) {
        accounts.removeAll { $0.devicePath == devicePath }
        readErrors.removeValue(forKey: devicePath)
    }

    func dropAll() {
        accounts.removeAll()
        readErrors.removeAll()
    }

    // MARK: - Enrolment

    /// Creates an account on the key.
    ///
    /// Portable is not just a flag: it costs a second touch and produces a backup key that
    /// the caller must show the user immediately. Returning it here rather than storing it
    /// keeps that value out of the store's memory a moment longer than necessary.
    func enroll(accountId: String,
                kind: AccountKind,
                devicePath: String,
                importedKeyB64: String?,
                onStep: @escaping @Sendable (PortableEnrollmentStep) -> Void) async throws -> (Account, String?) {
        guard let provider = pinProviderFor(devicePath) else { throw KeyLockedError() }

        let result: (Account, String?)
        switch kind {
        case .portable:
            result = try await worker.run {
                try $0.enrollPortable(accountId: accountId,
                                      devicePath: devicePath,
                                      askPIN: provider,
                                      importedKeyB64: importedKeyB64,
                                      onStep: onStep)
            }
        case .local:
            let account = try await worker.run {
                try $0.enroll(accountId: accountId, kind: .local, devicePath: devicePath, askPIN: provider)
            }
            result = (account, nil)
        }

        accounts.append(result.0)
        accounts.sort { $0.id < $1.id }
        return result
    }

    func delete(_ account: Account) async throws {
        guard let path = account.devicePath else { throw KeyLockedError() }
        guard let pin = pinFor(path) else { throw KeyLockedError() }
        try await worker.run { try $0.deleteAccount(account, pin: pin) }
        accounts.removeAll { $0.id == account.id && $0.devicePath == path }
    }

    // MARK: - Key material

    func exportBackupKey(for account: Account) async throws -> String {
        guard let path = account.devicePath, let provider = pinProviderFor(path) else {
            throw KeyLockedError()
        }
        return try await worker.run { try $0.exportImportedKey(account, pinProvider: provider) }
    }

    func deriveEncryptionKey(for account: Account, label: String) async throws -> EncryptionKey {
        guard let path = account.devicePath, let provider = pinProviderFor(path) else {
            throw KeyLockedError()
        }
        return try await worker.run { try $0.deriveEncryptionKey(account: account, label: label, pinProvider: provider) }
    }
}
