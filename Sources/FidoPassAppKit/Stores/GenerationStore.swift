import FidoPassCore
import Foundation

/// Password generation and the life of the result.
///
/// Holds at most one result at a time. A derived password is worth less the longer it is
/// kept, and holding several would mean deciding which of them a stale label invalidates.
@MainActor
final class GenerationStore: ObservableObject {

    struct Result: Equatable {
        let ref: AccountRef
        let label: String
        let password: String
        var revealed: Bool
    }

    @Published private(set) var result: Result?
    @Published private(set) var receipt: ClipboardReceipt?
    /// Seconds left before the clipboard is cleared, or nil when nothing of ours is there.
    @Published private(set) var secondsUntilClear: Int?
    /// The account currently waiting for a touch, if any.
    @Published private(set) var busyRef: AccountRef?

    private let worker: KeyWorker
    private let clipboard: ClipboardService
    private let pinProviderFor: (String) -> (@Sendable () -> String?)?
    var onAuthenticationFailure: ((String) -> Void)?
    private var lifetime = OperationLease()
    private var receiptID = UUID()
    private var countdown: Task<Void, Never>?

    init(worker: KeyWorker, clipboard: ClipboardService, pinProvider: @escaping (String) -> (@Sendable () -> String?)?) {
        self.worker = worker
        self.clipboard = clipboard
        self.pinProviderFor = pinProvider
    }

    deinit {
        countdown?.cancel()
    }

    // MARK: - Generation

    func generate(_ handle: AccountHandle, label: String) async throws -> String {
        guard let provider = pinProviderFor(handle.devicePath) else { throw KeyLockedError() }
        let ref = AccountRef(handle)
        lifetime.invalidate()
        let token = OperationLease()
        lifetime = token
        busyRef = ref
        defer { if lifetime === token { busyRef = nil } }

        let password: String
        do { password = try await worker.accounts(validity: token) {
            guard provider() != nil else { throw KeyLockedError() }
            return try $0.generatePassword(handle, label: label, pinProvider: provider)
        } } catch {
            try KeyOperationContext.check(token)
            if KeyFailurePolicy.invalidatesPINSession(error) { onAuthenticationFailure?(handle.devicePath) }
            throw error
        }
        try KeyOperationContext.check(token)
        result = Result(ref: ref, label: label, password: password, revealed: false)
        return password
    }

    func reveal(_ revealed: Bool) {
        guard var current = result else { return }
        current.revealed = revealed
        result = current
    }

    /// Drops passwords derived for a different account or label; labels compare by bytes.
    func invalidateResult(unless ref: AccountRef, label: String) {
        guard let current = result else { return }
        if current.ref != ref || !current.label.utf8.elementsEqual(label.utf8) { result = nil }
    }

    func clearResult() { lifetime.invalidate(); lifetime = OperationLease(); result = nil }

    /// Drops the on-screen result for a key that is no longer usable.
    ///
    /// The clipboard receipt deliberately survives: a password copied a moment ago is still
    /// on the clipboard whether or not the key that produced it is still plugged in, and the
    /// countdown is the only thing telling the user so. Only a session lock, which wipes the
    /// clipboard outright, takes it away.
    func dropEverything(forDevicePath path: String? = nil) {
        lifetime.invalidate()
        lifetime = OperationLease()
        busyRef = nil
        if let path {
            if result?.ref.devicePath == path { result = nil }
        } else {
            result = nil
            stopCountdown()
        }
    }

    // MARK: - Clipboard

    @discardableResult
    func copy(_ secret: String, as item: ClipboardReceipt.Item, for ref: AccountRef) -> Bool {
        let id = UUID()
        receiptID = id
        let deadline = clipboard.copySecret(secret) { [weak self] in
            Task { @MainActor in
                guard let self, self.receiptID == id else { return }
                self.markClipboardCleared()
            }
        }
        guard clipboard.lastWriteSucceeded else { receipt = nil; stopCountdown(); return false }
        receipt = ClipboardReceipt(ref: ref, item: item, copiedAt: Date(), clearsAt: deadline)
        startCountdown()
        return true
    }

    /// Puts an identity on the clipboard. Not a secret, so no timeout and no receipt — it
    /// exists to be pasted — but the same concealed path as everything else, so it is not
    /// synced to other devices either.
    func copyIdentity(_ identity: AccountIdentity) {
        receiptID = UUID()
        receipt = nil
        stopCountdown()
        clipboard.copySecret(identity.groupedHex, clearAfter: 0)
    }

    /// Wipes our own secret from the clipboard right now, if it is still ours.
    func clearClipboard() {
        clipboard.clearIfOwned()
        markClipboardCleared()
    }

    private func markClipboardCleared() {
        receipt?.clearsAt = nil
        stopCountdown()
    }

    private func startCountdown() {
        countdown?.cancel()
        secondsUntilClear = receipt?.secondsUntilClear(at: Date())
        // Ticking only while a secret is actually on the clipboard: an always-running timer
        // would redraw the HUD once a second for no reason.
        countdown = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                let remaining = self.receipt?.secondsUntilClear(at: Date())
                self.secondsUntilClear = remaining
                if remaining == nil { return }
            }
        }
    }

    private func stopCountdown() {
        countdown?.cancel()
        countdown = nil
        secondsUntilClear = nil
    }
}
