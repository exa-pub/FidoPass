import FidoPassCore
import Foundation

/// A reset in progress.
///
/// Reset is the one operation that destroys more than the delete screen does, and the key
/// dictates its shape: most authenticators accept a reset only within seconds of power-up,
/// so a physical reconnect is part of the flow rather than a nicety.
struct ResetFlow: Equatable {
    enum Stage: Equatable {
        /// Reading what will be lost, and confirming it.
        case confirm
        /// "Unplug the key" — waiting for it to disappear.
        case unplug
        /// "Plug it back in" — the reset fires the instant it returns.
        case replug
        case running
    }

    struct Doomed: Equatable, Identifiable {
        let ref: AccountRef
        let kind: AccountKind
        var id: String { ref.accountId }
    }

    var stage: Stage = .confirm
    var deviceName: String
    /// Checked inside the reset itself, after the reconnect. A different AAGUID means a
    /// different key came back; a matching one proves nothing.
    var expectedAAGUID: String?
    /// What is on the key, when it could be read. A locked key cannot be enumerated — and
    /// a locked-out key is the most common reason to reset one — so this may be empty for
    /// a key that is anything but.
    var doomed: [Doomed]
    var accountsReadable: Bool
    /// Label histories to forget afterwards. Collected now: they are keyed by credential
    /// id, and after the reset there is nothing left to ask for one.
    var scopes: [LabelScope]
    var acknowledged = false
    var typed = ""

    var hasLocalAccounts: Bool { doomed.contains { $0.kind == .local } }

    /// A local account's passwords cannot be recovered by any means, so erasing one asks
    /// for more than a click. Portable accounts have a backup key; an unreadable key has
    /// nothing to enumerate and nothing to spell out.
    var requiresTypedConfirmation: Bool { hasLocalAccounts }

    /// Whether the key is *known* to hold nothing.
    ///
    /// An empty `doomed` is not the same as an empty key: a locked key cannot be
    /// enumerated, so the list is empty precisely when the contents are unknown. Waiving
    /// the acknowledgement on that would skip the warning in the one case where the user
    /// has the least idea what they are about to erase.
    var isKnownEmpty: Bool { doomed.isEmpty && accountsReadable }

    var canProceed: Bool {
        guard acknowledged || isKnownEmpty else { return false }
        guard requiresTypedConfirmation else { return true }
        return typed == "RESET"
    }
}
