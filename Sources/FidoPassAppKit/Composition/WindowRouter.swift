import Foundation
import FidoPassCore

/// Window actions available to stores, implemented by AppWindows or a test recorder.
@MainActor
protocol WindowRouter: AnyObject {
    func openPanel()
    func openPanelForIncomingLink()
    func closePanel()
    func openManager()
    func openPreferences()
    #if FIDOPASS_VIRTUAL_KEYS
    func openVirtualDevices()
    #endif
    /// The sending window, optionally with a key already in it — the one the panel just
    /// issued for `account`, or one clicked as a link. One window; a second call fills the
    /// one that is open.
    func openEncryptor(with key: EncryptionKeyURL?, issuedFor account: Account?)
    /// The receiving window, over the store that binds it to a key. One window; a store
    /// that is already on screen is brought to the front.
    func openDecryptor(_ store: MessageDecryptStore)
    func closeDecryptor()
    /// Runs the save dialog. The outcome comes back through `PanelStore.recoverySheetFinished`.
    func saveRecoverySheet(_ sheet: RecoverySheet)
    func quit()
}

extension WindowRouter {
    func openPanelForIncomingLink() { openPanel() }
}
