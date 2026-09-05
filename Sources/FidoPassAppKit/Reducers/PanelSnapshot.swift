import Foundation
import FidoPassCore

/// The inputs the primary action depends on, flattened so it can be decided without the
/// stores. The click budget in `ai.tmp/HUD-PLAN.md` is enforced here rather than described:
/// with a key unlocked and an account preselected the answer must be `generateAndCopy`, not
/// "select an account first".
struct PanelSnapshot: Equatable {
    var hasDevices: Bool
    var selectedDevicePath: String?
    var isUnlocked: Bool
    /// Whether the selected key has a PIN. `nil` means it has not been asked — which is not
    /// "no PIN", and must not route anywhere destructive or misleading.
    var keyHasPIN: Bool?
    var accountRefs: [AccountRef]
    /// Portable accounts in the v1 layout, on a key that can hold the v2 one. Generating for
    /// one is refused until it has been migrated, so the primary action for it is the
    /// migration, not a password.
    var legacyRefs: Set<AccountRef> = []
    /// Credentials without a usable record: nothing is derived from them, and the only thing
    /// to do with one is delete it. `⏎` must not pretend otherwise.
    var incompleteRefs: Set<AccountRef> = []
    var selection: AccountRef?
    var hasValidLabel = true
}
