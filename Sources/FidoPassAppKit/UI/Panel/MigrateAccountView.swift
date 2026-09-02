import SwiftUI
import FidoPassCore

/// Giving a portable account from before identities one.
///
/// The identity is random unless the user says otherwise, and the field is there for the
/// one reason to say otherwise: the same account, already migrated on another key, shows
/// an identity — entering it here makes both keys agree about what is the same account.
struct MigrateAccountView: View {
    @ObservedObject var store: PanelStore
    let ref: AccountRef

    private enum Field: Hashable { case identity }
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelScreenHeader(title: "Migrate account", subtitle: ref.accountId) { store.backToAccounts() }

            VStack(alignment: .leading, spacing: 9) {
                Text("This account was created by an earlier version and has no identity yet. Migration writes a 12-byte identity next to the key material on the security key. Passwords do not change. Needs the PIN, no touch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    TextField("Identity, 24 hex characters", text: $store.migrationDraft.identityHex)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .focused($focus, equals: .identity)
                        .onSubmit { Task { await store.migrate() } }
                    Button {
                        store.migrationDraft.randomise()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Pick a random identity")
                }

                if let error = store.migrationDraft.error {
                    Text(error).font(.caption2).foregroundStyle(.red)
                } else if let identity = store.migrationDraft.identity {
                    IdentityFingerprintView(identity: identity)
                }

                Text("If this account already exists on another key and was migrated there, enter the identity that key shows — both keys should show the same fingerprint.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("Cancel") { store.backToAccounts() }
                        .keyboardShortcut(.cancelAction)
                    Button("Migrate") { Task { await store.migrate() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(store.migrationDraft.identity == nil || store.isWorking)
                }
            }
            .padding(.horizontal, PanelMetrics.padding)
            .padding(.bottom, 12)
        }
        .tabFocusChain([Field.identity], focus: $focus)
        .onAppear { focus = .identity }
    }
}
