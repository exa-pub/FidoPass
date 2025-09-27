import SwiftUI
import FidoPassCore
#if canImport(AppKit)
import AppKit
#endif

struct ContentView: View {
    @EnvironmentObject var vm: AccountsViewModel
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        NavigationView {
            DeviceSidebarView(viewModel: vm)
            AccountColumnView(viewModel: vm)
            AccountDetailContainerView(viewModel: vm)
        }
        .sheet(isPresented: $vm.showNewAccountSheet) { NewAccountView() }
        .alert("Delete account?", isPresented: $vm.showDeleteConfirm, presenting: vm.accountPendingDeletion) { _ in
            Button("Cancel", role: .cancel) { vm.accountPendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let account = vm.accountPendingDeletion { vm.deleteAccount(account) }
                vm.accountPendingDeletion = nil
            }
        } message: { account in
            Text("Are you sure you want to delete ‘\(account.id)’?")
        }
        .alert("Error", isPresented: Binding(get: { vm.errorMessage != nil }, set: { _ in vm.errorMessage = nil })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .onAppear {
            vm.reload()
            if vm.labelInput.isEmpty { vm.labelInput = "default" }
        }
        .onChange(of: vm.selectedDevicePath) { newValue in
            guard let selected = vm.selected else { return }
            if selected.devicePath != newValue { vm.selected = nil }
        }
        .toolbar {
            ToolbarButtons(onNewAccount: { vm.showNewAccountSheet = true }, onReload: vm.reload)
        }
    }

    static func relativeTime(from date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func copyToPasteboard(_ string: String) {
    #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    #endif
    }
}

private struct ToolbarButtons: ToolbarContent {
    let onNewAccount: () -> Void
    let onReload: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button(action: onNewAccount) { Image(systemName: "plus") }
                .help("New account")
            Button(action: onReload) { Image(systemName: "arrow.clockwise") }
                .help("Refresh list")
        }
    }
}

private struct DeviceSidebarView: View {
    @ObservedObject var viewModel: AccountsViewModel

    var body: some View {
        List(selection: Binding(get: { viewModel.selectedDevicePath }, set: { viewModel.selectedDevicePath = $0 })) {
            Section {
                if viewModel.devices.isEmpty {
                    DeviceSidebarEmptyState()
                } else {
                    ForEach(viewModel.devices, id: \.path) { device in
                        DeviceSidebarRow(device: device,
                                         state: viewModel.deviceStates[device.path],
                                         accountCount: accountCount(for: device),
                                         onReload: viewModel.reload,
                                         onLock: { viewModel.lockDevice(device) })
                        .tag(device.path as String?)
                    }
                }
            } header: {
                Text("Devices")
                    .textCase(.uppercase)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 240)
        .listStyle(.sidebar)
    }

    private func accountCount(for device: FidoPassCore.FidoDevice) -> Int {
        viewModel.accounts.filter { $0.devicePath == device.path }.count
    }
}

private struct DeviceSidebarEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No devices")
                .font(.headline)
            Text("Connect a FIDO key to manage accounts.")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 24)
    }
}

private struct DeviceSidebarRow: View {
    let device: FidoPassCore.FidoDevice
    let state: AccountsViewModel.DeviceState?
    let accountCount: Int
    let onReload: () -> Void
    let onLock: () -> Void

    var body: some View {
        let unlocked = state?.unlocked == true
        let statusText = unlocked ? (accountCount == 0 ? "Ready, no accounts" : "Ready, \(accountCount)") : "PIN required"

        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(unlocked ? Color.green.opacity(0.16) : Color.secondary.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: unlocked ? "key.fill" : "lock.fill")
                    .foregroundColor(unlocked ? .green : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.body)
                    .foregroundColor(.primary)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()

            if unlocked {
                Text("\(accountCount)")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundColor(.accentColor)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
        .contextMenu {
            Button("Refresh", action: onReload)
            if unlocked { Button("Lock", action: onLock) }
        }
    }
}

private struct AccountColumnView: View {
    @ObservedObject var viewModel: AccountsViewModel

    var body: some View {
        VStack(spacing: 0) {
            AccountColumnHeader(viewModel: viewModel)
            Divider()
            content
        }
        .frame(minWidth: 320)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.devices.isEmpty {
            NoDevicesState()
        } else if let path = viewModel.selectedDevicePath, let state = viewModel.deviceStates[path] {
            if state.unlocked {
                AccountListView(viewModel: viewModel, devicePath: path)
            } else {
                UnlockPromptView(viewModel: viewModel, device: state.device)
            }
        } else {
            SelectDeviceState()
        }
    }
}

private struct AccountColumnHeader: View {
    @ObservedObject var viewModel: AccountsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Accounts")
                        .font(.title3)
                        .fontWeight(.semibold)
                    if let subtitle = headerSubtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if canCreateAccount {
                    Button {
                        viewModel.showNewAccountSheet = true
                    } label: {
                        Label("Add", systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            SearchField(text: $viewModel.accountSearch)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.03))
    }

    private var headerSubtitle: String? {
        guard !viewModel.devices.isEmpty else { return "Connect a device to view accounts" }
        guard let path = viewModel.selectedDevicePath, let state = viewModel.deviceStates[path] else { return "Select a device on the left" }
        if !state.unlocked { return "Device is locked — enter the PIN" }

        let total = viewModel.accounts.filter { $0.devicePath == path }.count
        let filtered = filteredAccountsCount(for: path)

        if total == 0 { return "No accounts on this device yet" }
        if viewModel.accountSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Total: \(total)"
        }
        return "Found: \(filtered) of \(total)"
    }

    private func filteredAccountsCount(for path: String) -> Int {
        filteredAccounts(for: path).count
    }

    private func filteredAccounts(for path: String) -> [Account] {
        let query = viewModel.accountSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewModel.accounts.filter { account in
            guard account.devicePath == path else { return false }
            guard !query.isEmpty else { return true }
            return account.id.localizedCaseInsensitiveContains(query) || account.rpId.localizedCaseInsensitiveContains(query)
        }
    }

    private var canCreateAccount: Bool {
        guard let path = viewModel.selectedDevicePath, let state = viewModel.deviceStates[path] else { return false }
        return state.unlocked
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Search accounts", text: $text)
                .textFieldStyle(.plain)
                .disableAutocorrection(true)
            if !text.isEmpty {
                Button {
                    withAnimation { text = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
        .accessibilityLabel("Search accounts")
        .frame(maxWidth: 420)
    }
}

private struct AccountListView: View {
    @ObservedObject var viewModel: AccountsViewModel
    let devicePath: String

    var body: some View {
        let accounts = filteredAccounts
        List(selection: $viewModel.selected) {
            if accounts.isEmpty {
                AccountEmptyStateView(onCreate: { viewModel.showNewAccountSheet = true }, onClearSearch: { withAnimation { viewModel.accountSearch = "" } })
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                ForEach(accounts) { account in
                    AccountRowView(viewModel: viewModel, account: account)
                        .tag(account as Account?)
                }
            }
        }
        .listStyle(.inset)
    }

    private var filteredAccounts: [Account] {
        let query = viewModel.accountSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewModel.accounts.filter { account in
            guard account.devicePath == devicePath else { return false }
            guard !query.isEmpty else { return true }
            return account.id.localizedCaseInsensitiveContains(query) || account.rpId.localizedCaseInsensitiveContains(query)
        }
    }
}

private struct AccountEmptyStateView: View {
    let onCreate: () -> Void
    let onClearSearch: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("No accounts found")
                .font(.headline)
            Text("Create a new account or clear the search.")
                .font(.callout)
                .foregroundColor(.secondary)
            Button(action: onClearSearch) {
                Label("Clear search", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button(action: onCreate) {
                Label("Create account", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }
}

private struct AccountRowView: View {
    @ObservedObject var viewModel: AccountsViewModel
    let account: Account

    var body: some View {
        let isPortable = account.rpId == "fidopass.portable"
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isPortable ? Color.yellow.opacity(0.18) : Color.blue.opacity(0.16))
                    .frame(width: 40, height: 40)
                Image(systemName: isPortable ? "key.horizontal.fill" : "key.fill")
                    .foregroundColor(isPortable ? .orange : .blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(account.id)
                    .font(.body.weight(.medium))
                    .foregroundColor(.primary)
                Text(isPortable ? "Portable" : (account.rpId.isEmpty ? "No RP" : account.rpId))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if viewModel.generatingAccountId == account.id {
                ProgressView().controlSize(.small)
            }
            if viewModel.selected?.id == account.id {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { viewModel.selected = account }
        .contextMenu {
            Button(role: .destructive) {
                viewModel.accountPendingDeletion = account
                viewModel.showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button("Generate password") {
                viewModel.generatePassword(for: account, label: viewModel.labelInput)
            }
        }
    }
}

private struct UnlockPromptView: View {
    @ObservedObject var viewModel: AccountsViewModel
    let device: FidoPassCore.FidoDevice

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("\(device.displayName) is locked")
                .font(.headline)
            Text("Enter the PIN to unlock the device and view accounts.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            PinUnlockRow(viewModel: viewModel, device: device)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PinUnlockRow: View {
    @ObservedObject var viewModel: AccountsViewModel
    let device: FidoPassCore.FidoDevice

    var body: some View {
        HStack(spacing: 8) {
            SecureField("PIN", text: Binding(get: {
                viewModel.deviceStates[device.path]?.pin ?? ""
            }, set: { pin in
                var state = viewModel.deviceStates[device.path] ?? AccountsViewModel.DeviceState(device: device)
                state.pin = pin
                viewModel.deviceStates[device.path] = state
            }))
            .textFieldStyle(.roundedBorder)
            .frame(width: 160)

            Button {
                if let pin = viewModel.deviceStates[device.path]?.pin, !pin.isEmpty {
                    viewModel.unlockDevice(device, pin: pin)
                }
            } label: {
                Label("Unlock", systemImage: "lock.open")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Unlock the device with the provided PIN")
            .disabled((viewModel.deviceStates[device.path]?.pin ?? "").isEmpty)
        }
    }
}

private struct NoDevicesState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "usb.cable")
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            Text("Connect a device")
                .font(.headline)
            Text("FidoPass will show accounts as soon as a key is connected.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SelectDeviceState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "hand.point.left.fill")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("Select a device")
                .font(.headline)
            Text("Click a device in the sidebar to view its accounts.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AccountDetailContainerView: View {
    @ObservedObject var viewModel: AccountsViewModel

    var body: some View {
        Group {
            if let account = viewModel.selected, let path = account.devicePath, viewModel.deviceStates[path]?.unlocked == true {
                ScrollView {
                    AccountDetailView(viewModel: viewModel, account: account)
                }
            } else {
                AccountDetailPlaceholderView()
            }
        }
    }
}

private struct AccountDetailView: View {
    @ObservedObject var viewModel: AccountsViewModel
    let account: Account

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            AccountSummaryCard(account: account,
                               deviceName: deviceName,
                               lastCopied: viewModel.lastCopiedPasswordAt)
            PasswordGenerationSection(viewModel: viewModel,
                                      onGenerate: generatePassword,
                                      onGenerateAndCopy: generateAndCopy)
            if account.rpId == "fidopass.portable" {
                PortableAccountSection(onExport: exportMasterKey)
            }
            if let password = viewModel.generatedPassword {
                PasswordDisplayView(viewModel: viewModel, password: password)
            } else {
                PasswordPlaceholderView()
            }
            Spacer(minLength: 0)
        }
        .padding(24)
    }

    private var deviceName: String {
        guard let path = account.devicePath, let device = viewModel.deviceStates[path]?.device else { return "—" }
        return device.displayName
    }

    private func generatePassword() {
        viewModel.generatePassword(for: account, label: viewModel.labelInput)
    }

    private func generateAndCopy() {
        guard !viewModel.generating, !viewModel.labelInput.isEmpty else { return }
        viewModel.generating = true
        viewModel.generatingAccountId = account.id
        viewModel.generatedPassword = nil
        viewModel.showPlainPassword = false
        let pin = viewModel.deviceStates[account.devicePath ?? ""]?.pin
        Task {
            do {
                let password = try FidoPassCore.shared.generatePassword(account: account,
                                                                         label: viewModel.labelInput,
                                                                         requireUV: true,
                                                                         pinProvider: { pin })
                ContentView.copyToPasteboard(password)
                await MainActor.run { viewModel.markPasswordCopied() }
            } catch {
                await MainActor.run { viewModel.errorMessage = error.localizedDescription }
            }
            await MainActor.run {
                viewModel.generating = false
                viewModel.generatingAccountId = nil
            }
        }
    }

    private func exportMasterKey() {
        Task {
            do {
                let pin = viewModel.deviceStates[account.devicePath ?? ""]?.pin
                let imported = try FidoPassCore.shared.exportImportedKey(account,
                                                                         requireUV: true,
                                                                         pinProvider: { pin })
                await MainActor.run {
                    viewModel.generatedPassword = imported
                    viewModel.showPlainPassword = false
                }
            } catch {
                await MainActor.run { viewModel.errorMessage = error.localizedDescription }
            }
        }
    }

    private struct PasswordGenerationSection: View {
        @ObservedObject var viewModel: AccountsViewModel
        let onGenerate: () -> Void
        let onGenerateAndCopy: () -> Void

        var body: some View {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Password generation")
                        .font(.headline)
                    Text("Use labels to produce different passwords for one account. Recent labels are available from the menu on the right.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    LabelInputView(text: $viewModel.labelInput, recentLabels: $viewModel.recentLabels)
                    PasswordActionsView(isGenerating: viewModel.generating,
                                         canSubmit: canSubmit,
                                         onGenerate: onGenerate,
                                         onGenerateAndCopy: onGenerateAndCopy)
                }
            }
        }

        private var canSubmit: Bool {
            !viewModel.generating && !viewModel.labelInput.isEmpty
        }
    }

    private struct PortableAccountSection: View {
        let onExport: () -> Void

        var body: some View {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Portable account")
                        .font(.headline)
                    Text("Export the master key to move the account to another password manager or device.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 10) {
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
    }
}

private struct LabelInputView: View {
    @Binding var text: String
    @Binding var recentLabels: [String]

    var body: some View {
        HStack(spacing: 6) {
            TextField("Label", text: $text)
                .textFieldStyle(.roundedBorder)
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
        .frame(maxWidth: 360)
    }
}

private struct PasswordActionsView: View {
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

            Button(action: onGenerateAndCopy) {
                Label("Generate and copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Generate and copy immediately (hidden)")
            .disabled(!canSubmit)

            if isGenerating { ProgressView().controlSize(.small) }
        }
    }
}

private struct PasswordDisplayView: View {
    @ObservedObject var viewModel: AccountsViewModel
    let password: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Generated password")
                    .font(.headline)
                PasswordField(showPlainPassword: viewModel.showPlainPassword,
                              password: password,
                              onToggleVisibility: { withAnimation { viewModel.showPlainPassword.toggle() } },
                              onCopy: {
                                  ContentView.copyToPasteboard(password)
                                  viewModel.markPasswordCopied()
                              })
                if let copied = viewModel.lastCopiedPasswordAt {
                    Text("Copied \(ContentView.relativeTime(from: copied))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

private struct PasswordField: View {
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

private struct PasswordPlaceholderView: View {
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Password has not been generated yet")
                    .font(.headline)
                Text("Use the buttons above to generate a password — it will appear here and be ready to copy.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct AccountSummaryCard: View {
    let account: Account
    let deviceName: String
    let lastCopied: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                Label(account.id, systemImage: "key.fill")
                    .font(.title3.weight(.semibold))
                Spacer()
                if account.rpId == "fidopass.portable" {
                    Text("Portable")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundColor(.orange)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                InfoRow(icon: "globe", title: "RP ID", value: account.rpId.isEmpty ? "—" : account.rpId)
                InfoRow(icon: "usb.cable", title: "Device", value: deviceName)
                if let copied = lastCopied {
                    InfoRow(icon: "clock", title: "Last copied", value: ContentView.relativeTime(from: copied), accent: .secondary)
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }
}

private struct InfoRow: View {
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
            }
        }
    }
}

private struct AccountDetailPlaceholderView: View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NewAccountView: View {
    @EnvironmentObject var vm: AccountsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var accountId = ""
    @State private var isPortable = false
    @State private var importedKeyB64 = ""
    @State private var keyError: String? = nil
    @FocusState private var focused: Field?
    private enum Field { case account }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New account").font(.title2)
            TextField("ID", text: $accountId)
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: .account)
            Toggle("Portable (fidopass.portable)", isOn: $isPortable)
            if isPortable {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Imported key (32-byte ImportedKey base64) — leave empty to generate one")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Base64 ImportedKey", text: $importedKeyB64)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: importedKeyB64) { _ in validateKey() }
                    if let keyError {
                        Text(keyError)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            if vm.devices.count > 1 {
                Picker("Device", selection: Binding(get: { vm.selectedDevicePath ?? vm.devices.first?.path ?? "" }, set: { vm.selectedDevicePath = $0 })) {
                    ForEach(vm.devices.filter { vm.deviceStates[$0.path]?.unlocked == true }, id: \.path) { device in
                        Text(device.displayName).tag(device.path)
                    }
                }
                .pickerStyle(.menu)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    if isPortable {
                        vm.enrollPortable(accountId: accountId, importedKeyB64: importedKeyB64.isEmpty ? nil : importedKeyB64)
                    } else {
                        vm.enroll(accountId: accountId)
                    }
                }
                .disabled(!canCreate)
            }
        }
        .padding(24)
        .frame(minWidth: 360)
        .onAppear { DispatchQueue.main.async { focused = .account } }
    }

    private var canCreate: Bool {
        if accountId.isEmpty || vm.selectedDevicePath == nil { return false }
        if isPortable {
            if importedKeyB64.isEmpty { return true }
            return keyError == nil && (Data(base64Encoded: importedKeyB64)?.count == 32)
        }
        return true
    }

    private func validateKey() {
        guard !importedKeyB64.isEmpty else { keyError = nil; return }
        if let data = Data(base64Encoded: importedKeyB64), data.count == 32 {
            keyError = nil
        } else {
            keyError = "Requires 32-byte base64 value"
        }
    }
}
