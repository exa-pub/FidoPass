import FidoPassCore
import Foundation

/// Why the HUD was opened. Survives the PIN prompt so that unlocking continues the thing the
/// user actually asked for instead of dropping them on a list.
enum PanelIntent: Equatable {
    case copyPassword(AccountRef, label: String)
    case revealPassword(AccountRef, label: String)
    case enroll
    /// Open the receiving window — with a message already in it, when one was clicked.
    case decrypt(SealedMessageURL?)
}
