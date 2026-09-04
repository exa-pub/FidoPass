import FidoPassCore
import Foundation

/// Identity for a portable v1 migration. Editable for a new copy; fixed when resuming one.
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
