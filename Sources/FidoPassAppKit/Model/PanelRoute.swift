import FidoPassCore
import Foundation

/// What the HUD is showing.
enum PanelRoute: Equatable {
    case accounts
    case unlock
    /// The key has no PIN. Nothing else on it works until it does.
    case setPIN
    /// The key refuses everything until its PIN is changed, and changing it now lives in the
    /// manager window. A signpost, not a screen that does the work.
    case pinChangeRequired
    case enroll
    case backupKey(AccountRef)
    case confirmDelete(AccountRef)
    /// A portable account from before identities is being given one. Where generating for
    /// such an account lands, until it has been migrated.
    case migrate(AccountRef)
}
