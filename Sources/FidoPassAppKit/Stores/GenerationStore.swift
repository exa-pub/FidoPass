@preconcurrency import FidoPassCore
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

    /// Fired whenever the clipboard starts or stops holding one of our secrets.
    var onClipboardChanged: (() -> Void)?

    private let worker: KeyWorker
    private let pinProviderFor: (String) -> (() -> String?)?
    private var countdown: Task<Void, Never>?

    init(backend: KeyBackend, pinProvider: @escaping (String) -> (() -> String?)?) {
        self.worker = KeyWorker(backend: backend)
        self.pinProviderFor = pinProvider
    }

    deinit {
        countdown?.cancel()
    }

    // MARK: - Generation

    func generate(account: Account, label: String) async throws -> String {
        guard let path = account.devicePath, let provider = pinProviderFor(path) else {
            throw AccountStoreError.keyLocked
        }
        guard let ref = AccountRef(account) else { throw AccountStoreError.keyLocked }

        busyRef = ref
        defer { busyRef = nil }

        let password = try await worker.run {
            try $0.generatePassword(account: account, label: label, pinProvider: provider)
        }
        result = Result(ref: ref, label: label, password: password, revealed: false)
        return password
    }

    func reveal(_ revealed: Bool) {
        guard var current = result else { return }
        current.revealed = revealed
        result = current
    }

    /// Drops a result that no longer matches what the user is asking for.
    ///
    /// Editing the label used to leave the previous password on screen, so copying handed
    /// over a secret derived from something else.
    func invalidateResult(unless ref: AccountRef, label: String) {
        guard let current = result else { return }
        if current.ref != ref || current.label != label { result = nil }
    }

    func clearResult() { result = nil }

    /// Drops the on-screen result for a key that is no longer usable.
    ///
    /// The clipboard receipt deliberately survives: a password copied a moment ago is still
    /// on the clipboard whether or not the key that produced it is still plugged in, and the
    /// countdown is the only thing telling the user so. Only a session lock, which wipes the
    /// clipboard outright, takes it away.
    func dropEverything(forDevicePath path: String? = nil) {
        if let path {
            if result?.ref.devicePath == path { result = nil }
        } else {
            result = nil
            stopCountdown()
        }
    }

    // MARK: - Clipboard

    func copy(_ secret: String, as item: ClipboardReceipt.Item, for ref: AccountRef) {
        let deadline = ClipboardService.copySecret(secret) { [weak self] in
            Task { @MainActor in self?.markClipboardCleared() }
        }
        receipt = ClipboardReceipt(ref: ref, item: item, copiedAt: Date(), clearsAt: deadline)
        startCountdown()
        onClipboardChanged?()
    }

    /// Wipes our own secret from the clipboard right now, if it is still ours.
    func clearClipboard() {
        ClipboardService.clearIfOwned()
        markClipboardCleared()
    }

    private func markClipboardCleared() {
        receipt?.clearsAt = nil
        stopCountdown()
        onClipboardChanged?()
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
                if remaining == nil {
                    self.onClipboardChanged?()
                    return
                }
            }
        }
    }

    private func stopCountdown() {
        countdown?.cancel()
        countdown = nil
        secondsUntilClear = nil
    }
}
