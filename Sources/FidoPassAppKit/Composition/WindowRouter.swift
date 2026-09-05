import Foundation
import FidoPassCore

/// Window actions available to stores, implemented by AppWindows or a test recorder.
@MainActor
protocol WindowRouter: AnyObject {
    func openPanel()
    func openPanelForIncomingLink()
    func closePanel()
    func openManager(devicePath: String?)
    func openPreferences()
    #if FIDOPASS_VIRTUAL_KEYS
    func openVirtualDevices()
    #endif
    /// Public-key sharing and message composition have independent windows.
    func openEncryptionKey(_ key: EncryptionKeyURL, for account: Account)
    func openEncryptor(with key: EncryptionKeyURL?)
    /// The receiving window, over the store that binds it to a key. One window; a store
    /// that is already on screen is brought to the front.
    func openDecryptor(_ store: MessageDecryptStore)
    func closeDecryptor()
    /// Runs the save dialog. The outcome comes back through `PanelStore.recoverySheetFinished`.
    func saveRecoverySheet(_ sheet: RecoverySheet)
    func quit()
}

extension WindowRouter {
    func openManager() { openManager(devicePath: nil) }
    func openPanelForIncomingLink() { openPanel() }
}
