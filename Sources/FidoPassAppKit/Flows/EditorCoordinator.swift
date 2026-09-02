import Foundation

/// The text editor's lifetime, tied to the key it was opened from.
///
/// An editor session holds a live derived key for one account. Every path that revokes
/// access to that account — locking, unplugging, the session lock — has to take the window
/// with it, or "locked" would describe the account list while the secrets stayed reachable
/// in another window. This object remembers which key that is, and nothing else.
@MainActor
final class EditorCoordinator {

    private let router: WindowRouter
    /// Device whose key the open editor session belongs to, or nil when no editor is open.
    private(set) var boundDevicePath: String?

    init(router: WindowRouter) {
        self.router = router
    }

    func open(_ session: CryptoEditorSession, boundTo devicePath: String) {
        boundDevicePath = devicePath
        router.openEditor(session)
    }

    /// Closes the editor when it belongs to `path` — or unconditionally when `path` is nil.
    func close(ifBoundTo path: String?) {
        guard boundDevicePath != nil else { return }
        if let path, boundDevicePath != path { return }
        boundDevicePath = nil
        router.closeEditor()
    }

    /// The user closed the window themselves.
    func windowClosed() {
        boundDevicePath = nil
    }
}
