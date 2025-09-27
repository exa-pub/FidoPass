import SwiftUI
import FidoPassCore
import AppKit

struct ContentView: View {
    @EnvironmentObject var vm: AccountsViewModel
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        NavigationView {
            deviceSidebar
            accountColumn
            detailPane
        }
        .sheet(isPresented: $vm.showNewAccountSheet) { NewAccountView() }
        .alert("Delete account?", isPresented: $vm.showDeleteConfirm, presenting: vm.accountPendingDeletion) { acc in
            Button("Cancel", role: .cancel) { vm.accountPendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let a = vm.accountPendingDeletion { vm.deleteAccount(a) }
                vm.accountPendingDeletion = nil
            }
        } message: { acc in
            Text("Are you sure you want to delete ‘\(acc.id)’?")
        }
        .alert("Error", isPresented: Binding(get: { vm.errorMessage != nil }, set: { _ in vm.errorMessage = nil })) { Button("OK", role: .cancel) {} } message: { Text(vm.errorMessage ?? "") }
        .onAppear {
            vm.reload()
            if vm.labelInput.isEmpty { vm.labelInput = "default" }
        }
        .onChange(of: vm.selectedDevicePath) { newValue in
            guard let selected = vm.selected else { return }
            if selected.devicePath != newValue { vm.selected = nil }
        }
        .toolbar { toolbarButtons }
    }

    // MARK: - Sidebar
    private var deviceSidebar: some View {
        List(selection: Binding(get: { vm.selectedDevicePath }, set: { vm.selectedDevicePath = $0 })) {
            Section {
                if vm.devices.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No devices")
                            .font(.headline)
                        Text("Connect a FIDO key to manage accounts.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 24)
                } else {
                    ForEach(vm.devices, id: \.path) { dev in
                        deviceSidebarRow(for: dev, state: vm.deviceStates[dev.path])
                            .tag(dev.path as String?)
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

    private func deviceSidebarRow(for device: FidoPassCore.FidoDevice, state: AccountsViewModel.DeviceState?) -> some View {
        let unlocked = state?.unlocked == true
        let accountCount = vm.accounts.filter { $0.devicePath == device.path }.count
        let statusText = unlocked ? (accountCount == 0 ? "Ready, no accounts" : "Ready, \(accountCount)") : "PIN required"

        return HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(unlocked ? Color.green.opacity(0.16) : Color.secondary.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: unlocked ? "key.fill" : "lock.fill")
                    .foregroundColor(unlocked ? .green : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(deviceLabel(device))
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
            Button("Refresh") { vm.reload() }
            if unlocked { Button("Lock") { vm.lockDevice(device) } }
        }
    }

    // MARK: - Accounts column
    private var accountColumn: some View {
        VStack(spacing: 0) {
            accountColumnHeader
            Divider()
            Group {
                if vm.devices.isEmpty {
                    noDevicesState
                } else if let path = vm.selectedDevicePath, let state = vm.deviceStates[path] {
                    if state.unlocked {
                        accountList(for: path)
                    } else {
                        unlockPrompt(for: deviceLabel(state.device), device: state.device)
                    }
                } else {
                    selectDeviceState
                }
            }
        }
        .frame(minWidth: 320)
    }

    private var accountColumnHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Accounts")
                        .font(.title3)
                        .fontWeight(.semibold)
                    if let subtitle = accountHeaderSubtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if canCreateAccount {
                    Button {
                        vm.showNewAccountSheet = true
                    } label: {
                        Label("Add", systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            searchField
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.03))
    }

    private var accountHeaderSubtitle: String? {
        guard !vm.devices.isEmpty else { return "Connect a device to view accounts" }
        guard let path = vm.selectedDevicePath, let state = vm.deviceStates[path] else { return "Select a device on the left" }
        if !state.unlocked { return "Device is locked — enter the PIN" }
        let total = vm.accounts.filter { $0.devicePath == path }.count
        let filtered = filteredAccounts(for: path).count
        if total == 0 { return "No accounts on this device yet" }
        if vm.accountSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Total: \(total)" }
        return "Found: \(filtered) of \(total)"
    }

    private var canCreateAccount: Bool {
        guard let path = vm.selectedDevicePath, let state = vm.deviceStates[path] else { return false }
        return state.unlocked
    }

    @ViewBuilder
    private func accountList(for path: String) -> some View {
        let filtered = filteredAccounts(for: path)
        List(selection: $vm.selected) {
            if filtered.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No accounts found")
                        .font(.headline)
                    Text("Create a new account or clear the search.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Button {
                        withAnimation { vm.accountSearch = "" }
                    } label: {
                        Label("Clear search", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button {
                        vm.showNewAccountSheet = true
                    } label: {
                        Label("Create account", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
            } else {
                ForEach(filtered) { account in
                    accountRow(account)
                        .tag(account as Account?)
                }
            }
        }
        .listStyle(.inset)
    }

    private func accountRow(_ account: Account) -> some View {
        let isPortable = account.rpId == "fidopass.portable"
        return HStack(spacing: 12) {
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
            if vm.generatingAccountId == account.id { ProgressView().controlSize(.small) }
            if vm.selected?.id == account.id {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { vm.selected = account }
        .contextMenu {
            Button(role: .destructive) {
                vm.accountPendingDeletion = account
                vm.showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button("Generate password") {
                vm.generatePassword(for: account, label: vm.labelInput)
            }
        }
    }

    private func filteredAccounts(for path: String) -> [Account] {
        let query = vm.accountSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return vm.accounts.filter { acc in
            guard acc.devicePath == path else { return false }
            guard !query.isEmpty else { return true }
            return acc.id.localizedCaseInsensitiveContains(query) || acc.rpId.localizedCaseInsensitiveContains(query)
        }
    }

    private var noDevicesState: some View {
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

    private var selectDeviceState: some View {
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

    private func unlockPrompt(for label: String, device: FidoPassCore.FidoDevice) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("\(label) is locked")
                .font(.headline)
            Text("Enter the PIN to unlock the device and view accounts.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            pinUnlockRow(dev: device)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Detail pane
    private var detailPane: some View {
        Group {
            if let account = vm.selected, let path = account.devicePath, vm.deviceStates[path]?.unlocked == true {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        accountSummaryCard(for: account)
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Password generation")
                                    .font(.headline)
                                Text("Use labels to produce different passwords for one account. Recent labels are available from the menu on the right.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                labelInputBlock
                                generateBlock(acc: account)
                            }
                        }
                        if account.rpId == "fidopass.portable" {
                            portableSection(for: account)
                        }
                        if let password = vm.generatedPassword {
                            passwordSection(password)
                        } else {
                            noPasswordHint
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(24)
                }
            } else {
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
    }

    private func accountSummaryCard(for account: Account) -> some View {
        let deviceName = account.devicePath.flatMap { vm.deviceStates[$0]?.device }.map(deviceLabel) ?? "—"
        let rp = account.rpId.isEmpty ? "—" : account.rpId

        return VStack(alignment: .leading, spacing: 16) {
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
                infoRow(icon: "globe", title: "RP ID", value: rp)
                infoRow(icon: "usb.cable", title: "Device", value: deviceName)
                if let copied = vm.lastCopiedPasswordAt {
                    infoRow(icon: "clock", title: "Last copied", value: relativeTime(from: copied), accent: .secondary)
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }

    private func infoRow(icon: String, title: String, value: String, accent: Color = .accentColor) -> some View {
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

    private func portableSection(for account: Account) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Portable account")
                    .font(.headline)
                Text("Export the master key to move the account to another password manager or device.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button(action: { exportImportedKey(account) }) {
                        Label("Export master key", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Export the master key into the hidden password field")
                }
            }
        }
    }

    private func passwordSection(_ password: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Generated password")
                    .font(.headline)
                passwordBlock(password)
                if let copied = vm.lastCopiedPasswordAt {
                    Text("Copied \(relativeTime(from: copied))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var noPasswordHint: some View {
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

    private func relativeTime(from date: Date) -> String {
        ContentView.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Search accounts", text: $vm.accountSearch)
                .textFieldStyle(.plain)
                .disableAutocorrection(true)
            if !vm.accountSearch.isEmpty {
                Button {
                    withAnimation { vm.accountSearch = "" }
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

    private var labelInputBlock: some View {
        HStack(spacing: 6) {
            TextField("Label", text: $vm.labelInput)
                .textFieldStyle(.roundedBorder)
            Menu("⌄") {
                ForEach(vm.recentLabels, id: \.self) { l in Button(l) { vm.labelInput = l } }
                if !vm.recentLabels.isEmpty { Divider(); Button("Clear") { vm.recentLabels.removeAll() } }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .frame(maxWidth: 360)
    }

    private func generateBlock(acc: Account) -> some View {
        HStack(spacing: 12) {
            Button(action: { vm.generatePassword(for: acc, label: vm.labelInput) }) {
                Label("Generate", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Generate password")
            .disabled(vm.generating || vm.labelInput.isEmpty)

            Button(action: {
                guard !vm.generating, !vm.labelInput.isEmpty else { return }
                vm.generating = true
                let pin = vm.deviceStates[acc.devicePath ?? ""]?.pin
                Task {
                    defer { vm.generating = false }
                    do {
                        let pwd = try FidoPassCore.shared.generatePassword(account: acc, label: vm.labelInput, requireUV: true, pinProvider: { pin })
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pwd, forType: .string)
                        await MainActor.run { vm.markPasswordCopied() }
                    } catch { await MainActor.run { vm.errorMessage = error.localizedDescription } }
                }
            }) {
                Label("Generate and copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Generate and copy immediately (hidden)")
            .disabled(vm.generating || vm.labelInput.isEmpty)

            if vm.generating { ProgressView().controlSize(.small) }
        }
    }

    private func exportImportedKey(_ acc: Account) {
        Task {
            do {
                let pin = vm.deviceStates[acc.devicePath ?? ""]?.pin
                let imported = try FidoPassCore.shared.exportImportedKey(acc, requireUV: true, pinProvider: { pin })
                await MainActor.run {
                    vm.generatedPassword = imported
                    vm.showPlainPassword = false
                }
            } catch { await MainActor.run { vm.errorMessage = error.localizedDescription } }
        }
    }

    private func passwordBlock(_ pwd: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Group {
                if vm.showPlainPassword {
                    TextField("Password", text: .constant(pwd))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                } else {
                    SecureField("Password", text: .constant(pwd))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }
            Button(action: { withAnimation { vm.showPlainPassword.toggle() } }) {
                Image(systemName: vm.showPlainPassword ? "eye.slash" : "eye")
            }
            .help(vm.showPlainPassword ? "Hide" : "Show")
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pwd, forType: .string)
                vm.markPasswordCopied()
            }) { Image(systemName: "doc.on.doc") }
            .help("Copy password")
        }
        .transition(.opacity)
        .frame(maxWidth: 420)
    }

    private func pinUnlockRow(dev: FidoPassCore.FidoDevice) -> some View {
        HStack(spacing: 8) {
            SecureField("PIN", text: Binding(get: { vm.deviceStates[dev.path]?.pin ?? "" }, set: { pin in
                var st = vm.deviceStates[dev.path] ?? AccountsViewModel.DeviceState(device: dev)
                st.pin = pin
                vm.deviceStates[dev.path] = st
            }))
            .textFieldStyle(.roundedBorder)
            .frame(width: 160)
            Button {
                if let pin = vm.deviceStates[dev.path]?.pin, !pin.isEmpty {
                    vm.unlockDevice(dev, pin: pin)
                }
            } label: {
                Label("Unlock", systemImage: "lock.open")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Unlock the device with the provided PIN")
            .disabled((vm.deviceStates[dev.path]?.pin ?? "").isEmpty)
        }
    }

    private var toolbarButtons: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button { vm.showNewAccountSheet = true } label: { Image(systemName: "plus") }
                .help("New account")
            Button { vm.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh list")
        }
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
                    if let ke = keyError { Text(ke).font(.caption).foregroundColor(.red) }
                }
            }
            if vm.devices.count > 1 {
                Picker("Device", selection: Binding(get: { vm.selectedDevicePath ?? vm.devices.first?.path ?? "" }, set: { vm.selectedDevicePath = $0 })) {
                    ForEach(vm.devices.filter { vm.deviceStates[$0.path]?.unlocked == true }, id: \.path) { dev in
                        Text(deviceLabel(dev)).tag(dev.path)
                    }
                }.pickerStyle(.menu)
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
        if accountId.isEmpty || (vm.selectedDevicePath == nil) { return false }
        if isPortable {
            if importedKeyB64.isEmpty { return true }
            return keyError == nil && (Data(base64Encoded: importedKeyB64)?.count == 32)
        }
        return true
    }

    private func validateKey() {
        guard !importedKeyB64.isEmpty else { keyError = nil; return }
        if let d = Data(base64Encoded: importedKeyB64), d.count == 32 { keyError = nil } else { keyError = "Requires 32-byte base64 value" }
    }
}

private func deviceLabel(_ dev: FidoPassCore.FidoDevice) -> String {
    if dev.manufacturer.isEmpty { return dev.product }
    return "\(dev.manufacturer) \(dev.product)"
}
