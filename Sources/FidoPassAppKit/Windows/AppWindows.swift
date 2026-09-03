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
    weak var container: AppContainer?

    init() {}

    func openPanel() { panel?.show() }
    func closePanel() { panel?.hide() }
    func openManager() { auxiliary?.showAuthenticatorManager() }
    func openPreferences() { auxiliary?.showPreferences() }

    func openEncryptor(with key: EncryptionKeyURL?, issuedFor account: Account?) {
        auxiliary?.showEncryptor(key: key, issuedFor: account)
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
