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
            if account.rpId == "fidopass.portable" {
                PortableAccountSection(onExport: exportMasterKey)
            }
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

    private func exportMasterKey() {
        Task {
            guard let pinProvider = viewModel.makePinProvider(for: account.devicePath) else {
                if let path = account.devicePath {
                    viewModel.handlePinExpiration(for: path, notify: true)
                }
                return
            }
            do {
                let imported = try viewModel.core.exportImportedKey(account,
                                                                     requireUV: true,
                                                                     pinProvider: pinProvider)
                await MainActor.run {
                    viewModel.generatedPassword = imported
                    viewModel.showPlainPassword = false
                    viewModel.showToast("Master key exported",
                                         icon: "square.and.arrow.down",
                                         style: .warning,
                                         subtitle: "Revealed in the password field")
                }
            } catch {
                await MainActor.run { viewModel.errorMessage = error.localizedDescription }
            }
        }
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

    private var rpDisplay: String {
        if account.rpId.isEmpty { return "—" }
        return account.rpId
    }

    private var subtitle: String {
        if account.rpId == "fidopass.portable" { return "Portable credential" }
        if account.rpId.isEmpty || account.rpId == "fidopass.local" { return "Local credential" }
        return "Domain · \(account.rpId)"
    }

    private var trailingBadge: AnyView? {
        guard account.rpId == "fidopass.portable" else { return nil }
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
                                recentLabels: $viewModel.recentLabels,
                                canSubmit: canSubmit,
                                onSubmit: onGenerate)
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
                                  onCopy: {
                                      ClipboardService.copy(password)
                                      viewModel.markPasswordCopied()
                                  })
                    if let copied = viewModel.lastCopiedPasswordAt {
                        Text("Copied \(ContentView.relativeTime(from: copied))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Text("Generate a password above to display it here. It will remain hidden until you choose to reveal it.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var subtitle: String {
        if viewModel.generatedPassword == nil { return "No password generated yet" }
        return viewModel.showPlainPassword ? "Visible on screen" : "Hidden until revealed"
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
    @Binding var recentLabels: [String]
    let canSubmit: Bool
    let onSubmit: (() -> Void)?

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
                    Button("Clear") { recentLabels.removeAll() }
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
