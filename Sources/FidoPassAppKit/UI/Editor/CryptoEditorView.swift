import SwiftUI

/// Two panes over one key: plain text on the left, the encrypted value on the right.
///
/// Editing either side recomputes the other. Nothing here is written to disk, and the key
/// lives only as long as the window.
struct CryptoEditorView: View {
    @ObservedObject var session: CryptoEditorSession
    let onCopyPlaintext: (String) -> Void
    let onCopyCiphertext: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                plaintextPane
                Divider()
                ciphertextPane
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 380)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "lock.rectangle")
                    .foregroundColor(.accentColor)
                Text("\(session.accountId) · label “\(session.label)”")
                    .font(.headline)
                Spacer()
                if !session.isPortable {
                    Label("Not backed up", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .help("This account is bound to one key. If that key is lost, anything encrypted here cannot be recovered.")
                }
            }
            Text("The key is derived from your security key and never leaves this window. Nothing is saved.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var plaintextPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Plain text")
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)

            PlainTextEditor(text: $session.plaintext)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))

            HStack {
                Text("\(session.characterCount) / \(session.characterLimit)")
                    .font(.caption2)
                    .foregroundColor(session.characterCount > session.characterLimit ? .orange : .secondary)
                Spacer()
                Button("Copy") { onCopyPlaintext(session.plaintext) }
                    .controlSize(.small)
                    .disabled(session.plaintext.isEmpty)
                Button("Clear") { session.clear() }
                    .controlSize(.small)
                    .disabled(session.plaintext.isEmpty && session.ciphertext.isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
    }

    private var ciphertextPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Encrypted (base64)")
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)

            PlainTextEditor(text: $session.ciphertext, monospaced: true)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))

            HStack {
                StatusLabel(status: session.status)
                Spacer()
                Button("Copy") { onCopyCiphertext(session.ciphertext) }
                    .controlSize(.small)
                    .disabled(session.ciphertext.isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        Text("The encrypted value changes every time you edit — that is expected, and older values stay valid.")
            .font(.caption2)
            .foregroundColor(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Reports what the right pane currently holds.
///
/// Half-typed input is the normal state while pasting or editing, so it must not read as a
/// failure — only the states that really are wrong are coloured.
struct StatusLabel: View {
    let status: CryptoEditorSession.Status

    var body: some View {
        if let text {
            Label(text, systemImage: icon)
                .font(.caption2)
                .foregroundColor(color)
        }
    }

    private var text: String? {
        switch status {
        case .empty:                         return nil
        case .sealed:                        return "Encrypted"
        case .decrypted:                     return "Decrypted"
        case .incomplete:                    return "Waiting for a complete value"
        case .foreignFormat:                 return "Not a FidoPass value"
        case .unsupportedVersion(let value):  return "Written by a newer FidoPass (format \(value))"
        case .unreadable:                    return "Wrong account or label, or the data was changed"
        case .tooLarge(let limit):           return "Too long — the limit is \(limit) characters"
        case .keyExpired:                    return "The key expired — close and reopen the editor"
        }
    }

    private var icon: String {
        switch status {
        case .sealed, .decrypted: return "checkmark.shield"
        case .incomplete:         return "ellipsis"
        default:                  return "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch status {
        case .sealed, .decrypted: return .green
        case .incomplete:         return .secondary
        case .empty:              return .secondary
        default:                  return .orange
        }
    }
}
