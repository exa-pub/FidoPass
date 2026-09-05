import AppKit
import FidoPassCore

/// The real windows behind `WindowRouter`.
///
/// Late-bound on purpose: the panel's store needs a router before the panel controller can
/// exist, and the controller needs the store. This object is created first with nothing in
/// it, handed to the container, and filled in once the windows are built.
@MainActor
final class AppWindows: WindowRouter {

    var panel: PanelController?
    var auxiliary: AuxiliaryWindows?
    #if FIDOPASS_VIRTUAL_KEYS
    var virtualDevices: VirtualDevicesController?
    #endif
    weak var container: AppContainer?

    init() {}

    func openPanel() { panel?.show() }
    func openPanelForIncomingLink() { panel?.show(readKey: false) }
    func closePanel() { panel?.hide() }
    func openManager(devicePath: String?) { auxiliary?.showAuthenticatorManager(devicePath: devicePath) }
    func openPreferences() { auxiliary?.showPreferences() }
    #if FIDOPASS_VIRTUAL_KEYS
    func openVirtualDevices() { virtualDevices?.show() }
    #endif

    func openEncryptionKey(_ key: EncryptionKeyURL, for account: Account) {
        auxiliary?.showEncryptionKey(key, for: account)
    }

    func openEncryptor(with key: EncryptionKeyURL?) {
        auxiliary?.showEncryptor(key: key)
    }

    func openDecryptor(_ store: MessageDecryptStore) {
        auxiliary?.showDecryptor(store: store) { [weak self] in
            self?.container?.decryptor.windowClosed()
        }
    }

    func closeDecryptor() { auxiliary?.closeDecryptor() }
    func saveRecoverySheet(_ sheet: RecoverySheet) { panel?.presentSavePanel(for: sheet) }
    func quit() { NSApplication.shared.terminate(nil) }
}
