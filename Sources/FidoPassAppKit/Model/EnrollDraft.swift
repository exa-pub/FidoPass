import FidoPassCore
import Foundation

/// What the "new account" screen is collecting.
///
/// Three ways to get an account, one form. Import is not a third kind of account — it
/// creates a portable one from an existing backup — but it is a different thing to ask
/// for, with a different field and a different button, so the form names it separately
/// rather than hiding a text field under "Portable".
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
    /// The identity to give a backup that predates identities. `PanelStore` fills it with a
    /// random one the moment such a backup is recognised; it stays editable so the user can
    /// enter the identity the same account already shows on another key.
    var legacyIdentityHex = ""

    var trimmedId: String { accountId.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var trimmedImportText: String { importText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The pasted text, parsed. `nil` while it is empty or not a backup.
    var parsedBackup: PortableBackup? {
        guard !trimmedImportText.isEmpty else { return nil }
        return PortableBackup(base64: trimmedImportText)
    }

    /// A backup from before identities was pasted, so the identity field is on screen.
    var importIsLegacy: Bool { parsedBackup?.isLegacy == true }

    var legacyIdentity: AccountIdentity? { AccountIdentity(hex: legacyIdentityHex) }

    /// The backup to import, complete: a current one as pasted, or a legacy one with the
    /// chosen identity. `nil` until both halves are there.
    var parsedImport: PortableBackup? {
        guard let backup = parsedBackup else { return nil }
        if !backup.isLegacy { return backup }
        return legacyIdentity.map(backup.withIdentity)
    }

    /// Why the pasted text is not a backup. Only about the text: the identity field reports
    /// its own problem, so that a typo in one does not hide the other.
    var importError: String? {
        guard mode == .import, !trimmedImportText.isEmpty, parsedBackup == nil else { return nil }
        return "Requires a backup key: 60 characters, or 44 for one from an earlier version"
    }

    var legacyIdentityError: String? {
        guard importIsLegacy,
              !legacyIdentityHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              legacyIdentity == nil else { return nil }
        return "Identity is 24 hex characters (12 bytes)"
    }

    var canCreate: Bool {
        guard !trimmedId.isEmpty else { return false }
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
}
