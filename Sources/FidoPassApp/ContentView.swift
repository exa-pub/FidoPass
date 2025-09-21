import SwiftUI
import FidoPassCore
import AppKit

struct ContentView: View {
    @EnvironmentObject var vm: AccountsViewModel

    var body: some View {
        NavigationView {
            // Left: devices + accounts
            VStack(spacing: 6) {
                deviceStateChips
                accountList
            }
            .frame(minWidth: 240)
            .toolbar { toolbarButtons }

            // Right: detail
            detailPane
        }
        .sheet(isPresented: $vm.showNewAccountSheet) { NewAccountView() }
        .alert("Удалить учётку?", isPresented: $vm.showDeleteConfirm, presenting: vm.accountPendingDeletion) { acc in
            Button("Отмена", role: .cancel) { vm.accountPendingDeletion = nil }
            Button("Удалить", role: .destructive) {
                if let a = vm.accountPendingDeletion { vm.deleteAccount(a) }
                vm.accountPendingDeletion = nil
            }
        } message: { acc in
            Text("Вы уверены, что хотите удалить ‘\(acc.id)’?")
        }
    // undo banner removed
        .alert("Ошибка", isPresented: Binding(get: { vm.errorMessage != nil }, set: { _ in vm.errorMessage = nil })) { Button("OK", role: .cancel) {} } message: { Text(vm.errorMessage ?? "") }
        .onAppear { vm.reload(); if vm.labelInput.isEmpty { vm.labelInput = "default" } }
    }

    // MARK: - Device chips
    private var deviceStateChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.devices, id: \.path) { dev in
                    let st = vm.deviceStates[dev.path]
                    let unlocked = st?.unlocked == true
                    let count = vm.accounts.filter { $0.devicePath == dev.path }.count
                    let status = unlocked ? (count == 0 ? "Unlocked · No creds" : "Unlocked · \(count)") : "Locked"
                    Text(status)
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(
                            ZStack {
                                (unlocked ? Color.green.opacity(0.15) : Color.gray.opacity(0.15))
                                if vm.selectedDevicePath == dev.path {
                                    RoundedRectangle(cornerRadius: 30)
                                        .stroke(Color.accentColor.opacity(0.6), lineWidth: 1.2)
                                }
                            }
                        )
                        .foregroundColor(unlocked ? .green : .secondary)
                        .clipShape(Capsule())
                        .onTapGesture { vm.selectedDevicePath = dev.path }
                        .help(deviceLabel(dev))
                }
            }
            .padding(.horizontal, 8).padding(.top, 4)
        }
    }

    // MARK: - Account list
    private var accountList: some View {
        List(selection: $vm.selected) {
            ForEach(vm.devices, id: \.path) { dev in
                let state = vm.deviceStates[dev.path]
                Section(header: deviceHeader(dev, state: state)) {
                    if state?.unlocked == true {
                        let accounts = vm.accounts.filter { $0.devicePath == dev.path }.filter { acc in
                            let q = vm.accountSearch.trimmingCharacters(in: .whitespacesAndNewlines)
                            return q.isEmpty ? true : acc.id.localizedCaseInsensitiveContains(q)
                        }
                        if accounts.isEmpty {
                            Button { vm.showNewAccountSheet = true; vm.selectedDevicePath = dev.path } label: { Label("Создать первую", systemImage: "plus") }
                                .buttonStyle(.borderedProminent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(accounts) { acc in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        let isPortable = acc.rpId == "fidopass.portable"
                                        Image(systemName: isPortable ? "key.fill" : "key.fill")
                                            .foregroundColor(isPortable ? Color.yellow : Color.blue)
                                        Text(acc.id)
                                        Spacer()
                                        if vm.generatingAccountId == acc.id { ProgressView().controlSize(.mini) }
                                    }
                                    // userName removed; only id displayed
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                                .background(vm.selected?.id == acc.id ? Color.accentColor.opacity(0.10) : Color.clear)
                                .onTapGesture { vm.selected = acc }
                                .contextMenu {
                                    Button(role: .destructive) { vm.accountPendingDeletion = acc; vm.showDeleteConfirm = true } label: { Label("Удалить", systemImage: "trash") }
                                    Button("Сгенерировать пароль") { vm.generatePassword(for: acc, label: vm.labelInput) }
                                }
                                .tag(acc as Account?)
                            }
                        }
                    } else {
                        pinUnlockRow(dev: dev)
                    }
                }
            }
        }
    }

    // MARK: - Detail pane
    private var detailPane: some View {
        Group {
            if let acc = vm.selected, let path = acc.devicePath, vm.deviceStates[path]?.unlocked == true {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Учётка: \(acc.id)").font(.title3)
                    // userName removed
                    searchField
                    HStack(alignment: .top, spacing: 12) {
                        labelInputBlock
                        generateBlock(acc: acc)
                    }
                    if acc.rpId == "fidopass.portable" {
                        portableExportBlock(acc: acc)
                    }
                    if let pwd = vm.generatedPassword { passwordBlock(pwd) }
                    Spacer()
                }
                .padding()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "lock").font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("Разблокируйте устройство").font(.title3)
                    Text("Введите PIN и нажмите 'Разблокировать'.").foregroundStyle(.secondary)
                    searchField
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Поиск учёток", text: $vm.accountSearch)
                .textFieldStyle(.plain)
                .disableAutocorrection(true)
            if !vm.accountSearch.isEmpty {
                Button { withAnimation { vm.accountSearch = "" } } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
        .frame(maxWidth: 320)
        .accessibilityLabel("Поиск учёток")
    }

    private var labelInputBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                TextField("Метка (label)", text: $vm.labelInput)
                    .textFieldStyle(.roundedBorder)
                Menu("⌄") {
                    ForEach(vm.recentLabels, id: \.self) { l in Button(l) { vm.labelInput = l } }
                    if !vm.recentLabels.isEmpty { Divider(); Button("Очистить") { vm.recentLabels.removeAll() } }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .frame(maxWidth: 260)
        }
    }

    private func generateBlock(acc: Account) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: { vm.generatePassword(for: acc, label: vm.labelInput) }) {
                    Image(systemName: "wand.and.stars")
                }
                .help("Сгенерировать пароль")
                .disabled(vm.generating || vm.labelInput.isEmpty)

                Button(action: {
                    guard !vm.generating, !vm.labelInput.isEmpty else { return }
                    vm.generating = true
                    let pin = vm.deviceStates[acc.devicePath ?? ""]?.pin
                    Task {
                        defer { vm.generating = false }
                        do {
                            let pwd = try FidoPassCore.shared.generatePassword(account: acc, label: vm.labelInput, requireUV: true, pinProvider: { pin })
                            NSPasteboard.general.clearContents();
                            NSPasteboard.general.setString(pwd, forType: .string)
                            await MainActor.run { vm.markPasswordCopied() }
                        } catch { await MainActor.run { vm.errorMessage = error.localizedDescription } }
                    }
                }) {
                    Image(systemName: "doc.on.doc")
                }
                .help("Сгенерировать и сразу скопировать (скрыто)")
                .disabled(vm.generating || vm.labelInput.isEmpty)

                if vm.generating { ProgressView().controlSize(.small) }
            }
        }
    }

    private func portableExportBlock(acc: Account) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Portable аккаунт")
                .font(.subheadline)
                .foregroundColor(.secondary)
            HStack(spacing: 10) {
                Button(action: { exportImportedKey(acc) }) { Image(systemName: "square.and.arrow.down") }
                    .help("Экспорт Master-Key в поле пароля")
            }
            Text("После экспорта мастер-ключ попадёт в скрытое поле пароля")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.3)))
    }

    private func exportImportedKey(_ acc: Account) {
        Task {
            do {
                let pin = vm.deviceStates[acc.devicePath ?? ""]?.pin
                let imported = try FidoPassCore.shared.exportImportedKey(acc, requireUV: true, pinProvider: { pin })
                await MainActor.run {
                    vm.generatedPassword = imported
                    vm.showPlainPassword = false // keep hidden until user explicitly shows
                }
            } catch { await MainActor.run { vm.errorMessage = error.localizedDescription } }
        }
    }

    private func passwordBlock(_ pwd: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Group {
                if vm.showPlainPassword {
                    TextField("Пароль", text: .constant(pwd))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                } else {
                    SecureField("Пароль", text: .constant(pwd))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }
            Button(action: { withAnimation { vm.showPlainPassword.toggle() } }) {
                Image(systemName: vm.showPlainPassword ? "eye.slash" : "eye")
            }
            .help(vm.showPlainPassword ? "Скрыть" : "Показать")
            Button(action: {
                NSPasteboard.general.clearContents();
                NSPasteboard.general.setString(pwd, forType: .string)
                vm.markPasswordCopied()
            }) { Image(systemName: "doc.on.doc") }
            .help("Копировать пароль")
        }
        .transition(.opacity)
    }

    private func pinUnlockRow(dev: FidoPassCore.FidoDevice) -> some View {
        HStack(spacing: 8) {
            SecureField("PIN", text: Binding(get: { vm.deviceStates[dev.path]?.pin ?? "" }, set: { pin in
                var st = vm.deviceStates[dev.path] ?? AccountsViewModel.DeviceState(device: dev)
                st.pin = pin; vm.deviceStates[dev.path] = st
            }))
            .textFieldStyle(.roundedBorder)
            .frame(width: 120)
            Button("Разблокировать") { if let pin = vm.deviceStates[dev.path]?.pin, !pin.isEmpty { vm.unlockDevice(dev, pin: pin) } }
                .disabled((vm.deviceStates[dev.path]?.pin ?? "").isEmpty)
        }
    }

    private var toolbarButtons: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button { vm.showNewAccountSheet = true } label: { Image(systemName: "plus") }
                .help("Новая учётка")
            Button { vm.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Обновить список")
        }
    }

    // undoBanner removed
    // Copy toast could be shown elsewhere via overlay if desired (future)

    private func deviceHeader(_ dev: FidoPassCore.FidoDevice, state: AccountsViewModel.DeviceState?) -> some View {
        HStack {
            Text(deviceLabel(dev) + (state?.unlocked == true ? "" : " (заблок.)"))
            Spacer()
            if state?.unlocked == true { Button("Заблокировать") { vm.lockDevice(dev) }.buttonStyle(.link) }
        }
    }
}

struct NewAccountView: View {
    @EnvironmentObject var vm: AccountsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var accountId = ""
    @State private var isPortable = false
    @State private var importedKeyB64 = "" // if user supplies imported key (base64 of ImportedKey)
    @State private var keyError: String? = nil
    @FocusState private var focused: Field?
    private enum Field { case account }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Новая учётка").font(.title2)
            TextField("ID", text: $accountId)
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: .account)
            Toggle("Portable (fidopass.portable)", isOn: $isPortable)
            if isPortable {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Импортированный ключ (32 байта ImportedKey base64) — оставьте пустым чтобы сгенерировать")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Base64 ImportedKey", text: $importedKeyB64)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: importedKeyB64) { _ in validateKey() }
                    if let ke = keyError { Text(ke).font(.caption).foregroundColor(.red) }
                }
            }
            if vm.devices.count > 1 {
                Picker("Устройство", selection: Binding(get: { vm.selectedDevicePath ?? vm.devices.first?.path ?? "" }, set: { vm.selectedDevicePath = $0 })) {
                    ForEach(vm.devices.filter { vm.deviceStates[$0.path]?.unlocked == true }, id: \.path) { dev in
                        Text(deviceLabel(dev)).tag(dev.path)
                    }
                }.pickerStyle(.menu)
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Создать") {
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
        if let d = Data(base64Encoded: importedKeyB64), d.count == 32 { keyError = nil } else { keyError = "Нужен base64 32 байта" }
    }
}

private func deviceLabel(_ dev: FidoPassCore.FidoDevice) -> String {
    if dev.manufacturer.isEmpty { return dev.product }
    return "\(dev.manufacturer) \(dev.product)"
}
