import Foundation
import FidoPassCore

enum HUDReducer {

    static func primaryAction(_ snapshot: HUDSnapshot) -> HUDPrimaryAction {
        guard snapshot.hasDevices, let path = snapshot.selectedDevicePath else { return .connectKey }
        // Only a definite "no". An unasked key must not be offered a first PIN: it may
        // already have one, and the key refuses that request.
        if snapshot.keyHasPIN == false { return .setPIN(devicePath: path) }
        guard snapshot.isUnlocked else { return .unlock(devicePath: path) }
        if let selection = snapshot.selection, snapshot.accountRefs.contains(selection) {
            return .generateAndCopy(selection)
        }
        if let only = snapshot.accountRefs.first, snapshot.accountRefs.count == 1 {
            return .generateAndCopy(only)
        }
        return snapshot.accountRefs.isEmpty ? .createAccount : .chooseAccount
    }

    /// Picks the account the HUD should open on.
    ///
    /// Order matters: what the user used last, then the only account there is, then the
    /// first one. Choosing between one option is not a choice, so a single account is never
    /// presented as a list.
    static func resolveSelection(accounts: [Account],
                                 devices: [FidoDevice],
                                 memory: Preferences.LastUsed?) -> AccountRef? {
        if let memory {
            let matching = accounts.first { account in
                guard account.id == memory.accountId,
                      let path = account.devicePath,
                      let device = devices.first(where: { $0.path == path }) else { return false }
                return device.modelSignature == memory.deviceSignature
            }
            if let matching, let ref = AccountRef(matching) { return ref }
        }
        return accounts.compactMap(AccountRef.init).first
    }

    /// The label to start from: the last one used with this very account, and otherwise the
    /// conventional default.
    ///
    /// Nothing else is consulted. A label used with another account is not a candidate here
    /// — it would derive a valid, wrong password — and `Preferences.LastUsed.label` now says
    /// the same thing as the head of the account's own history, only for one account instead
    /// of all of them.
    static func resolveLabel(recent: [String]) -> String {
        recent.first ?? LabelStore.fallback
    }
}
