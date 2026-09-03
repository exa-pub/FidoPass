import SwiftUI
import FidoPassCore

/// Recreating a v1 portable account in the current layout.
///
/// Four touches: read the old record, create the new one, seal it, verify it — and only
/// then is the old record deleted, so a failure anywhere leaves every password where it
/// was. When an earlier attempt left its copy on the key, the screen offers to finish or
/// discard that instead of making another.
struct MigrateAccountView: View {
    @ObservedObject var store: PanelStore
    let ref: AccountRef

    private enum Field: Hashable { case identity }
    @FocusState private var focus: Field?

    private var copy: AccountHandle? { store.migrationCopy }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelScreenHeader(title: copy == nil ? "Migrate account" : "Finish migration", subtitle: ref.accountId) {
                store.backToAccounts()
            }

            VStack(alignment: .leading, spacing: 9) {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("IDENTITY")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)

                IdentityFieldView(hex: $store.migrationDraft.identityHex,
                                  identity: store.migrationDraft.identity,
                                  error: store.migrationDraft.error,
                                  isEditable: !store.migrationDraft.isFixed,
                                  onRandomise: { store.migrationDraft.randomise() },
                                  onSubmit: { Task { await store.migrate() } })
                    .focused($focus, equals: .identity)

                Text(identityHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    if copy != nil {
                        Button("Discard copy") { Task { await store.discardMigrationCopy() } }
                            .disabled(store.isWorking)
                            .help("Delete the unfinished copy and leave the account as it was")
                    }
                    Spacer()
                    Button("Cancel") { store.backToAccounts() }
                        .keyboardShortcut(.cancelAction)
                    Button(copy == nil ? "Migrate" : "Finish") { Task { await store.migrate() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(store.migrationDraft.identity == nil || store.isWorking)
                }
            }
            .padding(.horizontal, PanelMetrics.padding)
            .padding(.bottom, 12)
        }
        .tabFocusChain([Field.identity], focus: $focus)
        .onAppear { if !store.migrationDraft.isFixed { focus = .identity } }
    }

    private var explanation: String {
        guard let copy else {
            return "This account was created by an earlier version. Migration writes it again in the current layout — the same master key, so the same passwords — then verifies the new record and only then deletes the old one. Four touches."
        }
        if copy.account.canDerive {
            return "An earlier attempt left a finished copy on the key. Finishing verifies that the copy derives the same master key, then deletes the old record. Two touches."
        }
        return "An earlier attempt left an unfinished copy on the key — a credential without its record. Finishing removes it and runs the migration again with the same identity. Four touches."
    }

    private var identityHint: String {
        copy == nil
            ? "If this account already exists on another key in the current layout, enter the identity that key shows — both keys should show the same fingerprint."
            : "The identity the copy was created with. It is already on the key."
    }
}
