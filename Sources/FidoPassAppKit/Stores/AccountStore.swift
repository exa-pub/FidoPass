import FidoPassCore
import Foundation

/// Accounts read from the keys that are currently unlocked.
///
/// Nothing is cached across launches: account metadata lives on the authenticator, and the
/// only copy the app keeps is this in-memory one, for as long as the key stays unlocked.
@MainActor
final class AccountStore: ObservableObject {

    @Published private(set) var accounts: [AccountHandle] = []
    @Published private(set) var isLoading = false

    /// Read failures, per device path. Kept separate from a global error so one unreadable
    /// key never implies the others are broken too.
    @Published private(set) var readErrors: [String: PresentedError] = [:]

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

    /// Seals and opens text under a derived key — what the editor needs, and nothing else.
    var cipher: SecretCipher { worker.backend.cipher }

    func accounts(onDevice path: String) -> [AccountHandle] {
        accounts.filter { $0.devicePath == path }
    }

    func account(_ ref: AccountRef) -> AccountHandle? {
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

        var collected: [AccountHandle] = []
        var errors: [String: PresentedError] = [:]

        for path in unlockedPaths {
            guard let pin = pinFor(path) else { continue }
            for kind in AccountKind.allCases {
                do {
                    collected += try await worker.accounts { try $0.enumerateAccounts(kind: kind, devicePath: path, pin: pin) }
                } catch {
                    // Keep the first failure per key: later kinds usually fail for the same
                    // underlying reason and would only overwrite it.
                    if errors[path] == nil {
                        errors[path] = PresentedError(error)
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
                onStep: @escaping @Sendable (PortableEnrollmentStep) -> Void) async throws -> (AccountHandle, String?) {
        guard let provider = pinProviderFor(devicePath) else { throw KeyLockedError() }

        let result: (AccountHandle, String?)
        switch kind {
        case .portable:
            result = try await worker.accounts {
                try $0.enrollPortable(accountId: accountId,
                                      devicePath: devicePath,
                                      askPIN: provider,
                                      importedKeyB64: importedKeyB64,
                                      onStep: onStep)
            }
        case .local:
            let account = try await worker.accounts {
                try $0.enroll(accountId: accountId, kind: .local, devicePath: devicePath, askPIN: provider)
            }
            result = (account, nil)
        }

        accounts.append(result.0)
        accounts.sort { $0.id < $1.id }
        return result
    }

    func delete(_ handle: AccountHandle) async throws {
        guard let pin = pinFor(handle.devicePath) else { throw KeyLockedError() }
        try await worker.accounts { try $0.deleteAccount(handle, pin: pin) }
        accounts.removeAll { $0 == handle }
    }

    // MARK: - Key material

    func exportBackupKey(for handle: AccountHandle) async throws -> String {
        guard let provider = pinProviderFor(handle.devicePath) else { throw KeyLockedError() }
        return try await worker.accounts { try $0.exportImportedKey(handle, pinProvider: provider) }
    }

    func deriveEncryptionKey(for handle: AccountHandle, label: String) async throws -> EncryptionKey {
        guard let provider = pinProviderFor(handle.devicePath) else { throw KeyLockedError() }
        return try await worker.accounts { try $0.deriveEncryptionKey(handle, label: label, pinProvider: provider) }
    }
}
