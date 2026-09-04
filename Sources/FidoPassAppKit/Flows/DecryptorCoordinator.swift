import Foundation

/// Binds the receiving window and its cached keys to one connected key.
/// Closes on lock or disconnect; the key-independent sending window is unaffected.
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
