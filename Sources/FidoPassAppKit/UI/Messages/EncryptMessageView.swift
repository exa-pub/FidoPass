import SwiftUI
import FidoPassCore

/// Sending form with masked plaintext by default. Sealing requires no security key.
struct EncryptMessageView: View {
    @ObservedObject var store: MessageEncryptStore
    @Environment(\.clipboard) private var clipboard
    @State private var isTextRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            keySection
            Divider()
            textSection
            Divider()
            sealedSection
        }
        .frame(minWidth: 560, minHeight: 400)
    }

    // MARK: - Key

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "key.horizontal.fill")
                    .foregroundStyle(Color.accentColor)
                    .help("The encryption key — a fidopass.org/link or fidopass:// link")
                TextField("Paste an encryption-key link", text: $store.keyText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .autocorrectionDisabled()
                    .help(store.key?.payload ?? "The link someone gave you, or the one the panel just issued")
                Button("Paste") {
                    if let text = NSPasteboard.general.string(forType: .string) { store.keyText = text }
                }
                .controlSize(.small)
                Button("Copy key") {
                    // The key is public and exists to be handed out: no timeout.
                    if let key = store.key { clipboard?.copySecret(key.absoluteString, clearAfter: 0) }
                }
                .controlSize(.small)
                .disabled(store.key == nil)
            }
            HStack(spacing: 10) {
                keyStatus
                Spacer(minLength: 8)
                if let issuedFor = store.issuedFor {
                    issuedForLabel(issuedFor)
                }
            }
            .frame(minHeight: 20)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func issuedForLabel(_ account: Account) -> some View {
        HStack(spacing: 6) {
            Text("Key for “\(account.id)” · \(account.kind == .portable ? "Portable" : "Local")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if account.kind == .local {
                Label("Not backed up", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("This account is bound to one security key. This encryption key dies with it; nothing sealed under it can be recovered.")
            }
        }
    }

    @ViewBuilder
    private var keyStatus: some View {
        switch store.keyStatus {
        case .empty:
            Text("Anyone with a key link can encrypt for its owner; only the owner's security key decrypts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .incomplete:
            Label("Waiting for a complete link", systemImage: "ellipsis")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .verifying:
            Label("Checking the link…", systemImage: "ellipsis")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .invalid(let error):
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .valid(let fingerprint):
            KeyFingerprintView(fingerprint: fingerprint)
        }
    }

    // MARK: - Text

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Text")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.characterCount) / \(store.characterLimit)")
                    .font(.caption2)
                    .foregroundStyle(store.characterCount > store.characterLimit ? Color.orange : Color.secondary)
                RevealToggle(isRevealed: $isTextRevealed)
                Button("Clear") { store.clear() }
                    .controlSize(.small)
                    .disabled(store.plaintext.isEmpty && store.sealed.isEmpty)
            }
            PlainTextEditor(text: $store.plaintext, isMasked: !isTextRevealed)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sealed link

    private var sealedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .foregroundStyle(store.sealed.isEmpty ? Color.secondary : Color.accentColor)
                    .help("The sealed message — a fidopass.org/link or fidopass:// link")
                Text(store.sealed.isEmpty ? "The sealed message appears here" : store.sealed)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(store.sealed.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.12)))
                Button("Copy") {
                    // Not a secret, and it exists to be pasted elsewhere: wiping it mid-paste
                    // would be a defect, not protection.
                    clipboard?.copySecret(store.sealed, clearAfter: 0)
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(store.sealed.isEmpty)
            }
            HStack {
                statusLabel
                Spacer()
                Text("Every edit makes a new link; older links stay valid. Compare the six emoji with the key's owner first.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch store.status {
        case .empty:
            EmptyView()
        case .noKey:
            Label("Paste a key first", systemImage: "key")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .sealing:
            Label("Sealing…", systemImage: "ellipsis")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .sealed:
            Label("Sealed", systemImage: "checkmark.shield")
                .font(.caption2)
                .foregroundStyle(.green)
        case .tooLarge(let limit):
            Label("Too long — the limit is \(limit) characters", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .failed:
            Label("Could not seal the message", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }
}
