import SwiftUI
import FidoPassCore

/// The receiving window, top to bottom: the sealed link, one button, the text. Bound to the
/// security key named in the title.
///
/// The touch prompt is a strip in the button's row — the window has a message to keep on
/// screen while the key waits. The text is masked until asked for — bullets in the editor,
/// the shape of the text without a letter of it — because it is the secret the whole
/// exercise was about, and copying it does not need it on screen.
struct DecryptMessageView: View {
    @ObservedObject var store: MessageDecryptStore
    @ObservedObject private var touchGate: TouchGate
    @Environment(\.clipboard) private var clipboard
    @State private var isTextRevealed = false

    init(store: MessageDecryptStore, touchGate: TouchGate) {
        self.store = store
        self.touchGate = touchGate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            messageSection
            Divider()
            textSection
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    // MARK: - Message

    private var messageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .foregroundStyle(Color.accentColor)
                    .help("The sealed message — a fidopass.org/link or fidopass:// link")
                TextField("Paste a message link", text: $store.sealedText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .autocorrectionDisabled()
                Button("Paste") {
                    if let text = NSPasteboard.general.string(forType: .string) { store.sealedText = text }
                }
                .controlSize(.small)
            }
            if let prompt = touchGate.decryptorPrompt {
                TouchInlineView(prompt: prompt, onCancel: store.abandonTouch)
            } else {
                HStack(spacing: 10) {
                    statusLabel
                    Spacer(minLength: 8)
                    Text("Decrypting with \(store.deviceName)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Button("Decrypt ⏎") { Task { await store.decrypt() } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!store.canDecrypt)
                }
                .frame(minHeight: 22)
            }
            if let error = store.error {
                Text(error.fullText(includeDetails: false))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch store.status {
        case .empty:
            Text("One touch of the key per message.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .incomplete:
            Label("Waiting for a complete link", systemImage: "ellipsis")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .invalid(let error):
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
        case .locating:
            Label("Looking for the account…", systemImage: "ellipsis")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .noMatchingAccount:
            Label(store.hasLegacyAccounts
                  ? "No account on this key can open this — an account from an earlier version has to be migrated first"
                  : "No account on this key can open this message",
                  systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
        case .ready(let accountId):
            Label("For account “\(accountId)”", systemImage: "person.badge.key")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .decrypting:
            Label("Decrypting…", systemImage: "ellipsis")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .decrypted(let accountId):
            Label("Decrypted with “\(accountId)”", systemImage: "checkmark.shield")
                .font(.caption2)
                .foregroundStyle(.green)
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
                RevealToggle(isRevealed: $isTextRevealed)
                    .disabled(store.plaintext.isEmpty)
                Button("Copy") { clipboard?.copySecret(store.plaintext) }
                    .controlSize(.small)
                    .disabled(store.plaintext.isEmpty)
                Button("Clear") {
                    store.clear()
                    isTextRevealed = false
                }
                .controlSize(.small)
                .disabled(store.sealedText.isEmpty && store.plaintext.isEmpty)
            }
            PlainTextEditor(text: .constant(store.plaintext), isEditable: false, isMasked: !isTextRevealed)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
            Text("Nothing is saved. The text stays here until the window closes or the key locks; copying clears the clipboard after a while.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: store.plaintext.isEmpty) { _, isEmpty in
            // A new message starts hidden, whatever the previous one was.
            if isEmpty { isTextRevealed = false }
        }
    }
}
