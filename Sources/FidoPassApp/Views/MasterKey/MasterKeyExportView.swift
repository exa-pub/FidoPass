import SwiftUI

/// Presents a portable account's master key on its own terms.
///
/// This value reproduces every password the account will ever derive. It used to appear in
/// the field labelled "Generated password", where the obvious next step was to paste it
/// into a login box. A separate sheet, different wording and an explicit warning make what
/// it is unmistakable.
struct MasterKeyExportView: View {
    let export: AccountsViewModel.MasterKeyExport
    let onCopy: (String) -> Void
    let onDismiss: () -> Void

    @State private var isRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            warning
            keyField
            actions
        }
        .padding(24)
        .frame(minWidth: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(export.reason == .created ? "Backup key created" : "Backup key")
                .font(.title2.weight(.semibold))
            Text("Account “\(export.accountId)”")
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }

    private var warning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This is not a password", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundColor(.orange)
            Text("Anyone holding this key can reproduce every password of this account without the security key. Store it offline — a safe, a printed copy — and never paste it into a website.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Enter it on a second security key to make that key derive the same passwords. You can bring it back later with Export backup key.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.orange.opacity(0.30)))
    }

    private var keyField: some View {
        HStack(spacing: 8) {
            Group {
                if isRevealed {
                    TextField("", text: .constant(export.key))
                } else {
                    SecureField("", text: .constant(export.key))
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .disabled(true)

            Button {
                withAnimation { isRevealed.toggle() }
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
            }
            .help(isRevealed ? "Hide" : "Reveal")
        }
    }

    private var actions: some View {
        HStack {
            Button {
                onCopy(export.key)
            } label: {
                Label("Copy backup key", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button("Done", action: onDismiss)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}
