import SwiftUI
import FidoPassCore

/// Account creation/import form. Portable is the default; imports adopt the backup identity.
struct EnrollView: View {
    @ObservedObject var store: PanelStore

    private enum Field: Hashable { case accountId, importText, identity }
    @FocusState private var focus: Field?

    private var draft: EnrollDraft { store.enrollDraft }

    /// Only fields that are on screen: Tab must not stop at one that is not there.
    private var fields: [Field] {
        switch draft.mode {
        case .import:
            return [.accountId, .importText, .identity]
        case .portable, .local:
            return [.accountId, .identity]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelScreenHeader(title: "New account", subtitle: store.selectedDevice?.displayName) {
                store.backToAccounts()
            }

            if store.selectedKeyHoldsRecords {
                form
            } else {
                unsupportedKey
            }
        }
        .tabFocusChain(fields, focus: $focus)
        .onAppear { focus = .accountId }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField("Account ID, e.g. vault", text: $store.enrollDraft.accountId)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .accountId)
                .onSubmit { Task { await store.createAccount() } }

            Picker("", selection: $store.enrollDraft.mode) {
                ForEach(EnrollDraft.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(modeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if draft.mode == .import {
                importFields
            }

            identityFields

            if let step = store.enrollStep {
                Label(step, systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { store.backToAccounts() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.mode == .import ? "Import" : "Create") { Task { await store.createAccount() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canCreate || store.isWorking)
            }
        }
        .padding(.horizontal, PanelMetrics.padding)
        .padding(.bottom, 12)
    }

    /// A key with no large-blob store cannot hold an account record, so nothing can be
    /// created on it — while everything already on it keeps working.
    private var unsupportedKey: some View {
        VStack(alignment: .leading, spacing: 9) {
            PanelWarningBox(title: "This key cannot hold new accounts",
                          message: "Every new account keeps its record in the key's large-blob store, and this key has none — older firmware. Accounts already on it keep working as before.")
            HStack {
                Spacer()
                Button("Back") { store.backToAccounts() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, PanelMetrics.padding)
        .padding(.bottom, 12)
    }

    private var modeDescription: String {
        switch draft.mode {
        case .import:
            return "Paste the backup key of an existing portable account. This key will derive the same passwords and show the same identity."
        case .portable:
            return "Can be copied onto a second key, so these passwords survive losing this one. Recommended."
        case .local:
            return "Bound to this key alone. If it is lost or reset, these passwords cannot be recovered by any means."
        }
    }

    private var importFields: some View {
        VStack(alignment: .leading, spacing: 5) {
            SecureField("Backup key (base64)", text: $store.enrollDraft.importText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .focused($focus, equals: .importText)

            if let error = draft.importError {
                Text(error).font(.caption2).foregroundStyle(.red)
            } else if draft.parsedBackup == nil {
                Text("64 characters as shown on the other key's backup screen, or 44 from an earlier version.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var identityFields: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("IDENTITY")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)

            IdentityFieldView(hex: $store.enrollDraft.identityHex,
                              identity: draft.identity,
                              error: draft.identityError,
                              onRandomise: { store.randomiseEnrollIdentity() },
                              onSubmit: { Task { await store.createAccount() } })
                .focused($focus, equals: .identity)

            Text(identityHint)
                .font(.caption2)
                .foregroundStyle(draft.importIdentityDiffers ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var identityHint: String {
        if draft.importIdentityDiffers {
            return "Differs from the identity the backup carries — the two keys will not show the same identity."
        }
        switch draft.mode {
        case .import:
            return draft.importIsLegacy
                ? "This backup key predates identities. Enter the one the account shows on another key, or keep the random one."
                : "Carried by the backup key: the same identity as the account it came from."
        case .portable, .local:
            return "Not a secret and no part of any password. Tells this account apart from a namesake; a copy on a second key shows the same identity."
        }
    }
}
