import Foundation

/// The decrypting window's lifetime, tied to the key it was opened for.
///
/// That window holds live private keys for one security key's accounts. Every path that
/// revokes access to that key — locking, unplugging, the session lock — has to take the
/// window with it, or "locked" would describe the account list while the messages stayed
/// readable in another window. This object remembers which key that is, and which store,
/// so that a second message for the same key lands in the window that is already open.
///
/// The encrypting window is deliberately not here: it holds no key material.
@MainActor
final class DecryptorCoordinator {

    private let router: WindowRouter
    /// Device whose keys the open window derives, or nil when no window is open.
    private(set) var boundDevicePath: String?
    private(set) var store: MessageDecryptStore?

    init(router: WindowRouter) {
        self.router = router
    }

    func open(_ store: MessageDecryptStore, boundTo devicePath: String) {
        boundDevicePath = devicePath
        self.store = store
        router.openDecryptor(store)
    }

    /// Closes the window when it belongs to `path` — or unconditionally when `path` is nil.
    func close(ifBoundTo path: String?) {
        guard boundDevicePath != nil else { return }
        if let path, boundDevicePath != path { return }
        boundDevicePath = nil
        store?.close()
        store = nil
        router.closeDecryptor()
    }

    /// The user closed the window themselves.
    func windowClosed() {
        boundDevicePath = nil
        store = nil
    }
}
