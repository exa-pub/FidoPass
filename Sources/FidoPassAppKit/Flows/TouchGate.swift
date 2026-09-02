import Foundation

/// The one door to the key.
///
/// Every operation that makes the authenticator wait for a finger goes through
/// `withTouchPrompt`, so the prompt cannot be forgotten by a caller that is in a hurry —
/// the app once looked frozen while a key silently waited to be tapped, and this is what
/// stops that from happening again. The silent waits — PIN verification, deletion — go
/// through `withBusy` for the same reason: a screen that stays put while the key is being
/// asked reads as "nothing happened, type it again".
///
/// One gate for the whole application. `isWorking` is therefore app-wide — two windows may
/// not start key operations on top of each other — while what is *drawn* is per surface.
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

    init() {}

    /// The prompt the panel draws — nil when the wait belongs to another window.
    var panelPrompt: TouchPrompt? { surface == .panel ? prompt : nil }
    /// The prompt the manager draws.
    var managerPrompt: TouchPrompt? { surface == .manager ? prompt : nil }
    var panelBusyTitle: String? { surface == .panel ? busyTitle : nil }
    /// Whether the panel is in the middle of something — the reason it refuses to close.
    var isPanelBusy: Bool { isWorking && surface == .panel }

    /// Runs `body` with the prompt up, and takes it down whatever happens.
    func withTouchPrompt<T>(_ prompt: TouchPrompt,
                            surface: TouchSurface = .panel,
                            _ body: () async throws -> T) async rethrows -> T {
        self.surface = surface
        self.prompt = prompt
        isWorking = true
        defer {
            self.prompt = nil
            isWorking = false
        }
        return try await body()
    }

    /// Runs `body` as a silent wait with a title for the screen to show.
    func withBusy<T>(_ title: String,
                     surface: TouchSurface = .panel,
                     _ body: () async throws -> T) async rethrows -> T {
        self.surface = surface
        busyTitle = title
        isWorking = true
        defer {
            busyTitle = nil
            isWorking = false
        }
        return try await body()
    }

    /// Hides the prompt and abandons the result.
    ///
    /// libfido2 exposes `fido_dev_cancel`, but the repository does not surface the handle,
    /// so the operation itself finishes in the background — its result is simply discarded
    /// and never reaches the clipboard.
    func abandonTouch() {
        prompt = nil
        isWorking = false
    }
}
