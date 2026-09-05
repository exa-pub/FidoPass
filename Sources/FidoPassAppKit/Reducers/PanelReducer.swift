import Foundation
import FidoPassCore

enum PanelReducer {

    static func primaryAction(_ snapshot: PanelSnapshot) -> PanelPrimaryAction {
        guard snapshot.hasDevices, let path = snapshot.selectedDevicePath else { return .connectKey }
        // Only a definite "no". An unasked key must not be offered a first PIN: it may
        // already have one, and the key refuses that request.
        if snapshot.keyHasPIN == false { return .setPIN(devicePath: path) }
        guard snapshot.isUnlocked else { return .unlock(devicePath: path) }
        if let selection = snapshot.selection, snapshot.accountRefs.contains(selection) {
            return generateOrMigrate(selection, snapshot)
        }
        if let only = snapshot.accountRefs.first, snapshot.accountRefs.count == 1 {
            return generateOrMigrate(only, snapshot)
        }
        return snapshot.accountRefs.isEmpty ? .createAccount : .chooseAccount
    }

    /// The daily action — unless the account is a v1 portable one, for which the daily
    /// action is refused until it has been migrated. Migration is where `⏎` goes instead,
    /// so that the refusal is a screen that explains itself rather than an error. An
    /// incomplete credential derives nothing, and `⏎` does nothing for it.
    private static func generateOrMigrate(_ ref: AccountRef, _ snapshot: PanelSnapshot) -> PanelPrimaryAction {
        if snapshot.incompleteRefs.contains(ref) { return .chooseAccount }
        if snapshot.legacyRefs.contains(ref) { return .migrate(ref) }
        return snapshot.hasValidLabel ? .generateAndCopy(ref) : .editLabel
    }

    /// Picks the account the HUD should open on.
    ///
    /// Order matters: what the user used last, then the only account there is, then the
    /// first one. Choosing between one option is not a choice, so a single account is never
    /// presented as a list.
    static func resolveSelection(accounts: [AccountHandle],
                                 devices: [FidoDevice],
                                 memory: Preferences.LastUsed?) -> AccountRef? {
        if let credential = memory?.credentialId,
           let matching = accounts.first(where: { $0.credentialIdB64 == credential }) {
            return AccountRef(matching)
        }
        return accounts.first.map(AccountRef.init)
    }

    /// Starts with this credential’s latest label, or the conventional default.
    static func resolveLabel(recent: [String]) -> String {
        recent.first ?? LabelStore.fallback
    }
}
