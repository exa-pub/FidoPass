import Foundation

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
    func openEditor(_ session: CryptoEditorSession)
    func closeEditor()
    /// Runs the save dialog. The outcome comes back through `HUDStore.recoverySheetFinished`.
    func saveRecoverySheet(_ sheet: RecoverySheet)
    func quit()
}
