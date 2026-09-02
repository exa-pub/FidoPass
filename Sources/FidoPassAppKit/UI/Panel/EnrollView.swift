import SwiftUI
import FidoPassCore

/// Creating an account. Portable is the default because losing the only key that can derive
/// a vault master password is unrecoverable; Import is the same kind of account made from a
/// backup, and gets its own segment because it is a different thing to ask for.
struct EnrollView: View {
    @ObservedObject var store: PanelStore

    private enum Field: Hashable { case accountId, importText, legacyIdentity }
    @FocusState private var focus: Field?

    private var draft: EnrollDraft { store.enrollDraft }

    /// Only fields that are on screen: Tab must not stop at one that is not there.
    private var fields: [Field] {
        switch draft.mode {
        case .import:
            return draft.importIsLegacy ? [.accountId, .importText, .legacyIdentity] : [.accountId, .importText]
        case .portable, .local:
            return [.accountId]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelScreenHeader(title: "New account", subtitle: store.selectedDevice?.displayName) {
                store.backToAccounts()
            }

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
        .tabFocusChain(fields, focus: $focus)
        .onAppear { focus = .accountId }
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
            TextField("Backup key (base64)", text: $store.enrollDraft.importText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .focused($focus, equals: .importText)

            if let error = draft.importError {
                Text(error).font(.caption2).foregroundStyle(.red)
            } else if let backup = draft.parsedBackup {
                if backup.isLegacy {
                    legacyIdentityFields
                } else if let identity = backup.identity {
                    IdentityFingerprintView(identity: identity)
                    Text("Identity carried by this backup key — compare it with the other key.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("60 characters as shown on the other key's backup screen, or 44 from an earlier version.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A backup from before identities has none, so the account being created needs to be
    /// given one — the one the account already shows on another key, if it was migrated
    /// there, or a random one.
    private var legacyIdentityFields: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("This backup key predates identities. Enter the identity the other key shows after migration, or keep the random one.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                TextField("Identity, 24 hex characters", text: $store.enrollDraft.legacyIdentityHex)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .focused($focus, equals: .legacyIdentity)
                Button {
                    store.randomiseImportIdentity()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Pick a random identity")
            }

            if let error = draft.legacyIdentityError {
                Text(error).font(.caption2).foregroundStyle(.red)
            } else if let identity = draft.legacyIdentity {
                IdentityFingerprintView(identity: identity)
            }
        }
    }
}
