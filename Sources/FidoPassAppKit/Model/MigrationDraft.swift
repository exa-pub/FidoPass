import FidoPassCore
import Foundation

/// The identity a portable account from before identities is about to be given.
///
/// Random when the screen opens, and editable: if the same account was already migrated on
/// another key, the identity that key shows is the one to enter, so both keys show the same
/// fingerprint for what is the same account.
struct MigrationDraft: Equatable {
    var identityHex: String

    init(identity: AccountIdentity = .random()) {
        self.identityHex = identity.groupedHex
    }

    /// `nil` until the field holds 24 hex characters.
    var identity: AccountIdentity? { AccountIdentity(hex: identityHex) }

    var error: String? {
        guard !identityHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, identity == nil else { return nil }
        return "Identity is 24 hex characters (12 bytes)"
    }

    mutating func randomise() {
        identityHex = AccountIdentity.random().groupedHex
    }
}
