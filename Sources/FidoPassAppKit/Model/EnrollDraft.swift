import FidoPassCore
import Foundation

/// What the "new account" screen is collecting.
///
/// Three ways to get an account, one form. Import is not a third kind of account — it
/// creates a portable one from an existing backup — but it is a different thing to ask
/// for, with a different field and a different button, so the form names it separately
/// rather than hiding a text field under "Portable".
///
/// Every account gets an identity at creation, and the form is where it is chosen: random
/// unless the person types one — the one the same account already shows on another key,
/// say. An import starts from the identity its backup carries.
struct EnrollDraft: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case `import`, portable, local

        var id: String { rawValue }

        var title: String {
            switch self {
            case .import: return "Import"
            case .portable: return "Portable"
            case .local: return "Local"
            }
        }
    }

    var accountId = ""
    var mode: Mode = .portable
    /// The backup being imported, as pasted.
    var importText = ""
    /// The identity the account will be created with, as hex. Random when the form opens;
    /// replaced by the backup's the moment one that carries an identity is recognised.
    var identityHex: String
    /// The backup identity the field was last filled from, so that a person who types over
    /// it is not overwritten again on the next keystroke in the backup field.
    var adoptedImportIdentity: AccountIdentity?

    init(identity: AccountIdentity = .random()) {
        self.identityHex = identity.groupedHex
    }

    var trimmedId: String { accountId.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var trimmedImportText: String { importText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The pasted text, parsed. `nil` while it is empty or not a backup.
    var parsedBackup: PortableBackup? {
        guard !trimmedImportText.isEmpty else { return nil }
        return PortableBackup(base64: trimmedImportText)
    }

    /// A backup from before identities was pasted: it brings none, so the field's is used.
    var importIsLegacy: Bool { parsedBackup?.isLegacy == true }

    var identity: AccountIdentity? { AccountIdentity(hex: identityHex) }

    var identityError: String? {
        guard !identityHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, identity == nil else { return nil }
        return "Identity is 32 hex characters (16 bytes)"
    }

    /// The person typed an identity other than the one the backup carries. Allowed — but
    /// the two keys will then not show the same identity, and the form says so.
    var importIdentityDiffers: Bool {
        guard mode == .import, let carried = parsedBackup?.identity, let identity else { return false }
        return carried != identity
    }

    /// The backup to import, complete: the pasted one with the identity in the field. `nil`
    /// until both halves are there.
    var parsedImport: PortableBackup? {
        guard let backup = parsedBackup, let identity else { return nil }
        return backup.withIdentity(identity)
    }

    /// Why the pasted text is not a backup. Only about the text: the identity field reports
    /// its own problem, so that a typo in one does not hide the other.
    var importError: String? {
        guard mode == .import, !trimmedImportText.isEmpty, parsedBackup == nil else { return nil }
        return "Requires a backup key: 64 characters, or 44 for one from an earlier version"
    }

    var canCreate: Bool {
        guard !trimmedId.isEmpty, identity != nil else { return false }
        switch mode {
        case .local, .portable: return true
        case .import: return parsedImport != nil
        }
    }

    /// What to ask the store for, once the form is complete.
    var request: AccountStore.EnrollRequest? {
        guard canCreate else { return nil }
        switch mode {
        case .local: return .local
        case .portable: return .portable
        case .import: return parsedImport.map { .import($0) }
        }
    }

    mutating func randomiseIdentity() {
        identityHex = AccountIdentity.random().groupedHex
    }

    /// A backup carrying an identity the field has not been filled from yet.
    var hasUnadoptedImportIdentity: Bool {
        guard mode == .import, let carried = parsedBackup?.identity else { return false }
        return carried != adoptedImportIdentity
    }

    /// Fills the identity field from a newly recognised backup, once per backup.
    mutating func adoptImportIdentityIfNeeded() {
        guard hasUnadoptedImportIdentity, let carried = parsedBackup?.identity else { return }
        adoptedImportIdentity = carried
        identityHex = carried.groupedHex
    }
}
