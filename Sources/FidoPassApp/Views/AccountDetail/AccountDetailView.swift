import SwiftUI
import FidoPassCore

struct AccountDetailView: View {
    @ObservedObject var viewModel: AccountsViewModel
    let account: Account

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            AccountSummarySection(account: account,
                                  deviceName: deviceName,
                                  lastCopied: viewModel.lastCopiedPasswordAt)
            PasswordGenerationSection(viewModel: viewModel,
                                      accentColor: accountAccent,
                                      onGenerate: generatePassword,
                                      onGenerateAndCopy: generateAndCopy)
            if account.kind == .portable {
                PortableAccountSection(onExport: { viewModel.exportMasterKey(for: account) })
            }
            RecoverySection(onExport: { viewModel.exportRecoverySheet(for: account) })
            PasswordResultSection(viewModel: viewModel)
        }
        .padding(.bottom, 12)
    }

    private var deviceName: String {
        guard let path = account.devicePath,
              let device = viewModel.deviceStates[path]?.device else { return "—" }
        return device.displayName
    }

    private func generatePassword() {
        viewModel.generatePassword(for: account, label: viewModel.labelInput)
    }

    private func generateAndCopy() {
        guard !viewModel.generating, !viewModel.labelInput.isEmpty else { return }
        viewModel.generatePasswordAndCopy(for: account, label: viewModel.labelInput)
    }

    private var accountAccent: Color {
        guard let path = account.devicePath,
              let device = viewModel.deviceStates[path]?.device else { return .accentColor }
        return DeviceColorPalette.color(for: device)
    }
}

struct AccountSummarySection: View {
    let account: Account
    let deviceName: String
    let lastCopied: Date?

    var body: some View {
        SectionCard(icon: "key.fill",
                    title: account.id,
                    accent: .accentColor,
                    subtitle: subtitle,
                    trailing: trailingBadge) {
            VStack(alignment: .leading, spacing: 12) {
                InfoRow(icon: "usb.cable", title: "Device", value: deviceName)
                InfoRow(icon: "globe", title: "RP ID", value: rpDisplay)
                if let copied = lastCopied {
                    InfoRow(icon: "clock", title: "Last copied", value: ContentView.relativeTime(from: copied), accent: .secondary)
                }
            }
        }
    }

    private var rpDisplay: String { account.rpId }

    private var subtitle: String {
        switch account.kind {
        case .portable: return "Portable credential"
        case .local:    return "Local credential"
        }
    }

    private var trailingBadge: AnyView? {
        guard account.kind == .portable else { return nil }
        return AnyView(
            Text("Portable")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.orange.opacity(0.2)))
                .foregroundColor(.orange)
        )
    }
}

struct PasswordGenerationSection: View {
    @ObservedObject var viewModel: AccountsViewModel
    let accentColor: Color
    let onGenerate: () -> Void
    let onGenerateAndCopy: () -> Void

    var body: some View {
        SectionCard(icon: "wand.and.stars",
                    title: "Password generation",
                    accent: accentColor,
                    subtitle: "Use labels to derive deterministic passwords for this account.") {
            VStack(alignment: .leading, spacing: 12) {
                LabelInputView(text: $viewModel.labelInput,
                                recentLabels: viewModel.recentLabels,
                                canSubmit: canSubmit,
                                onSubmit: onGenerate,
                                onClearHistory: { viewModel.clearRecentLabels() })
                    .onChange(of: viewModel.labelInput) { _ in
                        viewModel.invalidateGeneratedPasswordIfLabelChanged()
                    }
                PasswordActionsView(isGenerating: viewModel.generating,
                                     canSubmit: canSubmit,
                                     onGenerate: onGenerate,
                                     onGenerateAndCopy: onGenerateAndCopy)
                if !viewModel.recentLabels.isEmpty {
                    Text("Recent labels: \(viewModel.recentLabels.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var canSubmit: Bool {
        !viewModel.generating && !viewModel.labelInput.isEmpty
    }
}

struct PortableAccountSection: View {
    let onExport: () -> Void

    var body: some View {
        SectionCard(icon: "key.horizontal",
                    title: "Portable account",
                    accent: .orange,
                    subtitle: "A master key can be exported for backup or migration.") {
            VStack(alignment: .leading, spacing: 10) {
                Label("Keep exported keys private", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.orange)
                Button(action: onExport) {
                    Label("Export master key", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Export the master key into the hidden password field")
            }
        }
    }
}

/// Offers the one piece of paper that makes this account survivable.
struct RecoverySection: View {
    let onExport: () -> Void

    var body: some View {
        SectionCard(icon: "doc.text",
                    title: "Recovery sheet",
                    accent: .blue,
                    subtitle: "What you would otherwise have to remember to reproduce these passwords.") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Passwords are derived from the key plus the account id, the label and the policy. The key is in your pocket; the rest is only in your head and on this Mac. Keep a copy with the key.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label("Contains no password, PIN or backup key — safe to print", systemImage: "checkmark.shield")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.green)
                Button(action: onExport) {
                    Label("Save recovery sheet…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

struct PasswordResultSection: View {
    @ObservedObject var viewModel: AccountsViewModel

    var body: some View {
        SectionCard(icon: "doc.on.doc",
                    title: "Generated password",
                    accent: .accentColor,
                    subtitle: subtitle) {
            if let password = viewModel.generatedPassword {
                VStack(alignment: .leading, spacing: 12) {
                    PasswordField(showPlainPassword: viewModel.showPlainPassword,
                                  password: password,
                                  onToggleVisibility: { withAnimation { viewModel.showPlainPassword.toggle() } },
                                  onCopy: { viewModel.copyGeneratedPassword(password) })
                    if let label = viewModel.generatedForLabel, !label.isEmpty {
                        Text("For label “\(label)”")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if let copied = viewModel.lastCopiedPasswordAt {
                        Text("Copied \(ContentView.relativeTime(from: copied)) · clipboard clears automatically")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Text(emptyStateText)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var subtitle: String {
        if viewModel.generatedPassword == nil { return "No password generated yet" }
        return viewModel.showPlainPassword ? "Visible on screen" : "Hidden until revealed"
    }

    private var emptyStateText: String {
        "Generate a password above to display it here. It stays hidden until you choose to reveal it, and anything copied is removed from the clipboard automatically."
    }
}

struct PasswordActionsView: View {
    let isGenerating: Bool
    let canSubmit: Bool
    let onGenerate: () -> Void
    let onGenerateAndCopy: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onGenerate) {
                Label("Generate", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Generate password")
            .disabled(!canSubmit)
            .keyboardShortcut(.return, modifiers: [.command])

            Button(action: onGenerateAndCopy) {
                Label("Generate and copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Generate and copy immediately (hidden)")
            .disabled(!canSubmit)
            .keyboardShortcut("c", modifiers: [.command, .shift])

            if isGenerating {
                ProgressView().controlSize(.small)
            }
        }
    }
}

struct PasswordField: View {
    let showPlainPassword: Bool
    let password: String
    let onToggleVisibility: () -> Void
    let onCopy: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Group {
                if showPlainPassword {
                    TextField("Password", text: .constant(password))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                } else {
                    SecureField("Password", text: .constant(password))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }
            Button(action: onToggleVisibility) {
                Image(systemName: showPlainPassword ? "eye.slash" : "eye")
            }
            .help(showPlainPassword ? "Hide" : "Show")
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy password")
        }
        .transition(.opacity)
        .frame(maxWidth: 420)
    }
}

struct InfoRow: View {
    let icon: String
    let title: String
    let value: String
    let accent: Color

    init(icon: String, title: String, value: String, accent: Color = .accentColor) {
        self.icon = icon
        self.title = title
        self.value = value
        self.accent = accent
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.body)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

struct LabelInputView: View {
    @Binding var text: String
    let recentLabels: [String]
    let canSubmit: Bool
    let onSubmit: (() -> Void)?
    let onClearHistory: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            TextField("Label", text: $text)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .onSubmit {
                    guard canSubmit else { return }
                    onSubmit?()
                }
            Menu("⌄") {
                ForEach(recentLabels, id: \.self) { label in
                    Button(label) { text = label }
                }
                if !recentLabels.isEmpty {
                    Divider()
                    Button("Clear", action: onClearHistory)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .frame(maxWidth: .infinity)
    }
}

struct AccountDetailPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Select an account")
                .font(.title3)
            Text("The sidebar lists accounts available on the selected device.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
