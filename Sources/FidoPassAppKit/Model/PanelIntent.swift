@preconcurrency import FidoPassCore
import Foundation

/// Why the HUD was opened. Survives the PIN prompt so that unlocking continues the thing the
/// user actually asked for instead of dropping them on a list.
enum PanelIntent: Equatable {
    case copyPassword(AccountRef, label: String)
    case revealPassword(AccountRef, label: String)
    case enroll
}
