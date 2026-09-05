import Foundation
import FidoPassCore

/// What `⏎` — and the big button — do in the current state.
enum PanelPrimaryAction: Equatable {
    case connectKey
    /// The key has no PIN at all. Until it gets one, nothing else on it can be done — so this
    /// outranks unlocking, which would only offer a field no PIN can satisfy.
    case setPIN(devicePath: String)
    case unlock(devicePath: String)
    case createAccount
    /// Several accounts and no valid selection: point at the list rather than derive from
    /// an arbitrary one. Deriving the wrong account's password is cheap to do and confusing
    /// to notice, since every password looks equally plausible.
    case chooseAccount
    case editLabel
    case generateAndCopy(AccountRef)
    /// The account would generate, but it predates identities: the one thing to do with it
    /// first is give it one.
    case migrate(AccountRef)
}
