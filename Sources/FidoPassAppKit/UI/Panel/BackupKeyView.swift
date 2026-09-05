import SwiftUI
import FidoPassCore

/// Backup presentation, separate from generated passwords. The identity is public.
struct BackupKeyView: View {
    @ObservedObject var store: PanelStore
    @ObservedObject private var generation: GenerationStore
    let ref: AccountRef
    @State private var revealed = false
    @State private var showsRecoveryDetails = false

    init(store: PanelStore, ref: AccountRef) {
        self.store = store
        self.generation = store.generation
        self.ref = ref
    }

    private var backup: PortableBackup? { store.backup }

    private var receipt: ClipboardReceipt? {
        guard let receipt = generation.receipt,
              receipt.ref == ref, receipt.item == .backupKey else { return nil }
        return receipt
    }

    private var copied: Bool { receipt != nil && generation.secondsUntilClear != nil }

    private var clipboardHint: String {
        if let seconds = generation.secondsUntilClear, receipt != nil {
            return "Clipboard clears in \(seconds)s"
        }
        if receipt != nil { return "No longer on the clipboard" }
        return "Clipboard clears automatically after \(Int(ClipboardService.defaultClearInterval))s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelScreenHeader(title: "Backup key", subtitle: ref.accountId) { store.backToAccounts() }

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Keep this key offline", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("Anyone with it can restore this account without your security key. Never use it as a password.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                secretCard

                HStack {
                    Button {
                        showsRecoveryDetails.toggle()
                    } label: {
                        Label("How to restore", systemImage: showsRecoveryDetails ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .accessibilityValue(showsRecoveryDetails ? "Expanded" : "Collapsed")
                    Spacer()
                    Button("Done") { store.backToAccounts() }
                        .controlSize(.small)
                }
                if showsRecoveryDetails { recoveryDetails }
            }
            .padding(.horizontal, PanelMetrics.padding)
            .padding(.bottom, 12)
        }
    }

    private var secretCard: some View {
        VStack(spacing: 8) {
            PlainTextEditor(text: .constant(backup?.base64 ?? ""), isEditable: false,
                            monospaced: true, isMasked: !revealed, isSingleLine: true)
                .frame(height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Backup key")
                .accessibilityValue(revealed ? (backup?.base64 ?? "") : "Hidden")

            HStack(spacing: 8) {
                Button {
                    revealed.toggle()
                } label: {
                    Label(revealed ? "Hide" : "Reveal", systemImage: revealed ? "eye.slash" : "eye")
                        .frame(width: 70, height: 18)
                }
                .accessibilityLabel(revealed ? "Hide backup key" : "Reveal backup key")

                Button(action: store.copyBackupKey) {
                    Label(copied ? "Copied" : "Copy backup key", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                        .frame(height: 18)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
            .disabled(backup == nil)

            Text(clipboardHint)
                .font(.caption2).monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 14)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var recoveryDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On another security key, create an account and choose Import. Paste this backup key to restore the same passwords.")
            if let identity = backup?.identity {
                IdentityFingerprintView(identity: identity)
                Text("Compare this public identity with the restored account.")
            } else if backup?.isLegacy == true {
                Text("This older backup has no identity. Import will ask you to choose one; migrating the original account adds it to future backups.")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
