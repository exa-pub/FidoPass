import SwiftUI
import FidoPassCore

/// The value that reproduces every password of a portable account.
///
/// It gets its own screen, its own wording and no resemblance to a password field: pasting
/// it into a login box would be a catastrophe, and the UI must make that impossible to do
/// by accident.
struct BackupKeyView: View {
    @ObservedObject var store: HUDStore
    let ref: AccountRef
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HUDScreenHeader(title: "Backup key", subtitle: ref.accountId) { store.backToAccounts() }

            VStack(alignment: .leading, spacing: 9) {
                HUDWarningBox(title: "This is not a password",
                              message: "Anyone holding this value can reproduce every password of this account without the security key. Store it offline — a safe, a printed copy — and never paste it into a website.")

                Text(revealed ? (store.backupKey ?? "") : String(repeating: "•", count: 32))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(7)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text("Enter it on a second security key to make that key derive the same passwords.")
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
            .padding(.horizontal, HUDMetrics.padding)
            .padding(.bottom, 12)
        }
    }
}
