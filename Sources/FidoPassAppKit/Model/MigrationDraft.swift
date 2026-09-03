import FidoPassCore
import Foundation

/// The identity the v2 copy of a v1 portable account is about to be created with.
///
/// Random when the screen opens, and editable: if the same account was already migrated on
/// another key, the identity that key shows is the one to enter, so both keys show the same
/// fingerprint for what is the same account. When an unfinished copy is already on the key,
/// its identity is the one being finished with, and the field is read-only.
struct MigrationDraft: Equatable {
    var identityHex: String
    /// The identity is the copy's — already in `user.id` on the key — and cannot change here.
    let isFixed: Bool

    init(identity: AccountIdentity = .random(), isFixed: Bool = false) {
        self.identityHex = identity.groupedHex
        self.isFixed = isFixed
    }

    /// `nil` until the field holds 32 hex characters.
    var identity: AccountIdentity? { AccountIdentity(hex: identityHex) }

    var error: String? {
        guard !identityHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, identity == nil else { return nil }
        return "Identity is 32 hex characters (16 bytes)"
    }

    mutating func randomise() {
        guard !isFixed else { return }
        identityHex = AccountIdentity.random().groupedHex
    }
}
