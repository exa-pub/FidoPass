import SwiftUI
import FidoPassCore

/// Sharing an account's public encryption key owns no sender draft or private key material.
struct ShareEncryptionKeyView: View {
    let key: EncryptionKeyURL
    let account: Account
    let onEncrypt: () -> Void
    @Environment(\.clipboard) private var clipboard
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Encryption key for “\(account.id)”")
                .font(.headline).lineLimit(2)
            Text(account.kind == .portable ? "Portable account" : "Local account")
                .font(.caption).foregroundStyle(.secondary)
            KeyFingerprintView(fingerprint: key.fingerprint)
            Text("Share this public link with the sender. Compare these six emoji over another trusted channel before they encrypt a message for you.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(key.absoluteString)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            if account.kind == .local {
                Label("If this security key is lost or reset, messages encrypted for this account cannot be recovered.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Previously issued links stay valid.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Encrypt a message…", action: onEncrypt)
                    .help("Use this key as the recipient of an encrypted message.")
                    .accessibilityIdentifier("share-key.encrypt")
                Spacer()
                Button(copied ? "Copied" : "Copy encryption key") {
                    clipboard?.copySecret(key.absoluteString, clearAfter: 0)
                    copied = clipboard?.lastWriteSucceeded == true
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 460)
    }
}
