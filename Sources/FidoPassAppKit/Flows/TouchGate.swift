import Foundation

/// App-wide operation ownership with per-surface prompts.
/// Use withTouchPrompt for touch operations and withBusy for silent waits.
@MainActor
final class TouchGate: ObservableObject {

    /// The key is waiting for a finger, wherever that is being shown.
    @Published private(set) var prompt: TouchPrompt?
    /// Where the current prompt or wait belongs. Set before `prompt`, so an observer of the
    /// prompt sees the surface it goes with.
    @Published private(set) var surface: TouchSurface = .panel
    /// A key operation is in flight, with or without a touch.
    @Published private(set) var isWorking = false
    /// What the app is doing while it makes the user wait, when no key touch is involved.
    @Published private(set) var busyTitle: String?

    private var owner: OperationLease?

    init() {}

    /// The prompt the panel draws — nil when the wait belongs to another window.
    var panelPrompt: TouchPrompt? { surface == .panel ? prompt : nil }
    /// The prompt the manager draws.
    var managerPrompt: TouchPrompt? { surface == .manager ? prompt : nil }
    /// The prompt the receiving window draws.
    var decryptorPrompt: TouchPrompt? { surface == .decryptor ? prompt : nil }
    var panelBusyTitle: String? { surface == .panel ? busyTitle : nil }
    /// Whether the panel is in the middle of something — the reason it refuses to close.
    var isPanelBusy: Bool { isWorking && owner?.isValid == true && surface == .panel }

    func withTouchPrompt<T>(_ prompt: TouchPrompt,
                            surface: TouchSurface = .panel,
                            _ body: () async throws -> T) async throws -> T {
        try await run(surface: surface, prompt: prompt, title: nil, body)
    }

    func withBusy<T>(_ title: String,
                     surface: TouchSurface = .panel,
                     _ body: () async throws -> T) async throws -> T {
        try await run(surface: surface, prompt: nil, title: title, body)
    }

    private func run<T>(surface: TouchSurface, prompt: TouchPrompt?, title: String?,
                        _ body: () async throws -> T) async throws -> T {
        guard owner == nil else { throw CancellationError() }
        let token = OperationLease()
        owner = token
        self.surface = surface
        self.prompt = prompt
        busyTitle = title
        isWorking = true
        defer {
            if owner === token {
                owner = nil
                self.prompt = nil
                busyTitle = nil
                isWorking = false
            }
        }
        return try await KeyOperationContext.$lease.withValue(token) {
            let result = try await body()
            try KeyOperationContext.check(token)
            return result
        }
    }

    /// Replaces what the prompt says while it is up — a multi-touch operation naming the
    /// step it is on. The title, the key and the clock stay as they are.
    func updatePrompt(message: String, ownedBy token: OperationLease?) {
        guard let token, owner === token, token.isValid, var current = prompt else { return }
        current.message = message
        prompt = current
    }

    /// Hides the prompt and abandons the result.
    ///
    /// libfido2 exposes `fido_dev_cancel`, but the repository does not surface the handle,
    /// so the operation itself finishes in the background — its result is simply discarded
    /// and never reaches the clipboard.
    func abandonTouch() {
        owner?.invalidate()
        prompt = nil
        busyTitle = nil
        // Ownership lasts until the synchronous call actually returns.
    }
}
