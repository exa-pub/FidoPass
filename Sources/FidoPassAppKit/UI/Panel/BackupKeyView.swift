import SwiftUI
import FidoPassCore

/// The value that reproduces every password of a portable account.
///
/// It gets its own screen, its own wording and no resemblance to a password field: pasting
/// it into a login box would be a catastrophe, and the UI must make that impossible to do
/// by accident.
///
/// The identity under it is shown unmasked. It is not a secret, and it is the one thing a
/// person can compare with a paper copy or with the other key without revealing anything.
struct BackupKeyView: View {
    @ObservedObject var store: PanelStore
    let ref: AccountRef
    @State private var revealed = false

    private var backup: PortableBackup? { store.backup }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelScreenHeader(title: "Backup key", subtitle: ref.accountId) { store.backToAccounts() }

            VStack(alignment: .leading, spacing: 9) {
                PanelWarningBox(title: "This is not a password",
                              message: "Anyone holding this value can reproduce every password of this account without the security key. Store it offline — a safe, a printed copy — and never paste it into a website.")

                Text(revealed ? (backup?.base64 ?? "") : String(repeating: "•", count: backup?.base64.count ?? 64))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(7)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                if let identity = backup?.identity {
                    IdentityFingerprintView(identity: identity)
                    Text("The identity is not a secret. Compare it with the account on the other key.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if backup?.isLegacy == true {
                    Text("This backup key predates identities and carries none. Importing it asks for one; migrating this account gives it one and puts it in future backups.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Enter it on a second security key (Import) to make that key derive the same passwords and show the same identity.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button(revealed ? "Hide" : "Reveal") { revealed.toggle() }
                        .controlSize(.small)
                    Button("Copy") { store.copyBackupKey() }
                        .controlSize(.small)
                    Spacer()
                    Button("Done") { store.backToAccounts() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, PanelMetrics.padding)
            .padding(.bottom, 12)
        }
    }
}
