import Foundation
import FidoPassCore

/// The windows, as the stores see them.
///
/// A store decides *that* a window should open or close; it never touches AppKit. Everything
/// that used to be an `onRequest…` closure on the panel's store is a method here, so a store
/// depends on one protocol instead of on six hooks that somebody has to remember to wire —
/// and a test can hand it a recorder instead of a window.
@MainActor
protocol WindowRouter: AnyObject {
    func openPanel()
    func closePanel()
    func openManager()
    func openPreferences()
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
