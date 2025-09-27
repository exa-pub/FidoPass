import SwiftUI
import FidoPassCore
#if canImport(AppKit)
import AppKit
import Carbon.HIToolbox
#elseif canImport(UIKit)
import UIKit
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
        .navigationViewStyle(.columns)
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
            if vm.selected?.devicePath != newValue {
                vm.selected = nil
                vm.selectDefaultAccount(for: newValue)
            }
        }
        .toolbar {
            ToolbarButtons(viewModel: vm,
                           onNewAccount: { vm.showNewAccountSheet = true },
                           onReload: vm.reload)
        }
        .overlay(alignment: .bottomTrailing) {
            ToastHostView(toast: vm.toastMessage)
                .padding(.trailing, 20)
                .padding(.bottom, 24)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: vm.toastMessage)
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

    static func preferEnglishKeyboardLayoutIfNeeded() {
    #if canImport(AppKit)
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        if languages(for: current).contains(where: { $0.hasPrefix("en") }) {
            return
        }

        let filter = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource,
            kTISPropertyInputSourceType: kTISTypeKeyboardLayout
        ] as CFDictionary

        guard let cfArray = TISCreateInputSourceList(filter, false)?.takeRetainedValue() else { return }
        var englishSource: TISInputSource?
        let preferredIDs: Set<String> = ["com.apple.keylayout.ABC", "com.apple.keylayout.US", "com.apple.keylayout.British"]
        let count = CFArrayGetCount(cfArray)
        for index in 0..<count {
            let raw = unsafeBitCast(CFArrayGetValueAtIndex(cfArray, index), to: TISInputSource.self)
            let languages = languages(for: raw)
            guard languages.contains(where: { $0.hasPrefix("en") }) else { continue }
            if englishSource == nil { englishSource = raw }
            if let id = inputSourceID(for: raw),
               preferredIDs.contains(id) {
                englishSource = raw
                break
            }
        }
        if let englishSource, englishSource != current {
            TISSelectInputSource(englishSource)
        }
    #endif
    }

    #if canImport(AppKit)
    private static func languages(for source: TISInputSource) -> [String] {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return [] }
        let array = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as NSArray
        return array.compactMap { $0 as? String }
    }

    private static func inputSourceID(for source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
    #endif
}

private struct ToolbarButtons: ToolbarContent {
    @ObservedObject var viewModel: AccountsViewModel
    let onNewAccount: () -> Void
    let onReload: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button(action: onNewAccount) { Image(systemName: "plus") }
                .help("New account")
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(viewModel.devices.filter { viewModel.deviceStates[$0.path]?.unlocked == true }.isEmpty)
            Button(action: onReload) { Image(systemName: "arrow.clockwise") }
                .help("Refresh device and account list")
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(viewModel.reloading)
            if viewModel.reloading {
                ProgressView()
                    .controlSize(.small)
                    .help("Refreshing data…")
            }
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
            DeviceAvatarView(device: device, isLocked: !unlocked)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .renderingMode(.template)
                        .symbolVariant(.fill)
                        .foregroundStyle(DeviceColorPalette.color(for: device))
                    Text(device.displayName)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(device.identityLabel)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
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
        .help(unlocked ? "Device is unlocked and ready" : "Device requires PIN")
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
    @FocusState private var searchFieldFocused: Bool

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
                Button {
                    viewModel.showNewAccountSheet = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(!canCreateAccount)
                .opacity(canCreateAccount ? 1 : 0.55)
                .help(canCreateAccount ? "Add a new account on the selected device" : "Unlock a device to add accounts")
            }
            SearchField(text: $viewModel.accountSearch, focus: $searchFieldFocused)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.03))
        .onReceive(viewModel.$focusSearchFieldToken) { _ in
            searchFieldFocused = true
        }
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
    var focus: FocusState<Bool>.Binding

    var body: some View {
        let isFocused = focus.wrappedValue
        let hasText = !text.isEmpty
        let borderColor: Color = isFocused ? Color.accentColor.opacity(0.6) : (hasText ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08))
        let borderWidth: CGFloat = isFocused ? 1.6 : 1.0
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Search accounts", text: $text)
                .textFieldStyle(.plain)
                .disableAutocorrection(true)
                .focused(focus)
            if !text.isEmpty {
                Button {
                    withAnimation { text = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Clear search")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(isFocused ? 0.07 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: borderWidth))
        .accessibilityLabel("Search accounts")
        .frame(maxWidth: 420)
        .animation(.easeInOut(duration: 0.18), value: isFocused)
        .animation(.easeInOut(duration: 0.18), value: hasText)
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
        .onDeleteCommand(perform: viewModel.requestDeleteSelectedAccount)
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
            Text("Tip: press ⌘N to add quickly.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

private struct AccountRowView: View {
    @ObservedObject var viewModel: AccountsViewModel
    let account: Account
    @State private var isHovering = false

    var body: some View {
        let isPortable = account.rpId == "fidopass.portable"
        let isSelected = viewModel.selected?.id == account.id && viewModel.selected?.devicePath == account.devicePath
        let accentColor = isPortable ? Color.orange : Color.accentColor
        let iconFill = isPortable ? Color.orange : Color.accentColor
        let backgroundColor: Color = {
            if isSelected { return Color.accentColor.opacity(0.18) }
            if isHovering { return Color.primary.opacity(0.06) }
            return Color.clear
        }()
        let borderColor: Color = isSelected ? Color.accentColor.opacity(0.35) : Color.clear
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(iconFill.opacity(isSelected ? 0.28 : (isHovering ? 0.22 : 0.16)))
                    .frame(width: 40, height: 40)
                Image(systemName: "key.fill")
                    .foregroundColor(accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(account.id)
                    .font(.body.weight(.medium))
                    .foregroundColor(isSelected ? .accentColor : .primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(isSelected ? .accentColor.opacity(0.75) : .secondary)
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
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowBackground(Color.clear)
        .onTapGesture { viewModel.selected = account }
        .onHover { hovering in isHovering = hovering }
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(account.id), \(isPortable ? "Portable" : (account.rpId.isEmpty ? "No RP" : account.rpId))"))
        .accessibilityHint(Text("Select to view account details"))
    }

    private var subtitle: String {
        if account.rpId == "fidopass.portable" {
            return "Portable credential"
        }
        if account.rpId.isEmpty {
            return "Local credential"
        }
        if account.rpId == "fidopass.local" {
            return "Local credential"
        }
        return "Domain · \(account.rpId)"
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
    @FocusState private var pinFocused: Bool

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
            .onSubmit(attemptUnlock)
            .focused($pinFocused)

            Button {
                attemptUnlock()
            } label: {
                Label("Unlock", systemImage: "lock.open")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Unlock the device with the provided PIN")
            .disabled((viewModel.deviceStates[device.path]?.pin ?? "").isEmpty)
        }
        .onChange(of: pinFocused) { isFocused in
            if isFocused {
                ContentView.preferEnglishKeyboardLayoutIfNeeded()
            }
        }
        .onChange(of: device.path) { _ in
            DispatchQueue.main.async {
                pinFocused = true
                ContentView.preferEnglishKeyboardLayoutIfNeeded()
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                pinFocused = true
                ContentView.preferEnglishKeyboardLayoutIfNeeded()
            }
        }
    }

    private func attemptUnlock() {
        if let pin = viewModel.deviceStates[device.path]?.pin, !pin.isEmpty {
            viewModel.unlockDevice(device, pin: pin)
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
        KeyTouchPromptContainer(configuration: keyTouchPromptConfiguration) {
            Group {
                if let account = viewModel.selected, let path = account.devicePath, viewModel.deviceStates[path]?.unlocked == true {
                    ScrollView {
                        AccountDetailView(viewModel: viewModel, account: account)
                            .frame(maxWidth: 560, alignment: .leading)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    AccountDetailPlaceholderView()
                        .frame(maxWidth: 480)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(detailBackground)
        }
    }

    private var keyTouchPromptConfiguration: KeyTouchPromptConfiguration? {
        guard let account = activeAccount else { return nil }
        return KeyTouchPromptConfiguration(title: "Touch your security key to generate",
                                           message: "Keep the key in contact until the password appears.",
                                           accent: accentColor(for: account),
                                           accessory: accessory(for: account))
    }

    private var activeAccount: Account? {
        guard viewModel.generating,
              let id = viewModel.generatingAccountId,
              let selected = viewModel.selected,
              selected.id == id else { return nil }
        return selected
    }

    private func accessory(for account: Account) -> KeyTouchPromptConfiguration.Accessory? {
        guard let path = account.devicePath,
              let device = viewModel.deviceStates[path]?.device else {
            return .custom(account.id)
        }
        return .deviceName(device.displayName)
    }

    private func accentColor(for account: Account) -> Color {
        guard let path = account.devicePath,
              let device = viewModel.deviceStates[path]?.device else { return .accentColor }
        return DeviceColorPalette.color(for: device)
    }
}

private var detailBackground: Color {
#if canImport(AppKit)
        return Color(nsColor: .underPageBackgroundColor)
#elseif canImport(UIKit)
        return Color(UIColor.systemGroupedBackground)
#else
        return Color.secondary.opacity(0.05)
#endif
    }

private struct DeviceMenuLabel: View {
    let device: FidoPassCore.FidoDevice

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                Text(device.identityLabel)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        } icon: {
            Image(systemName: "key.fill")
                .renderingMode(.template)
                .symbolVariant(.fill)
                .foregroundStyle(DeviceColorPalette.color(for: device))
        }
        .labelStyle(.titleAndIcon)
    }
}

private enum DeviceColorPalette {
    static let palette: [Color] = [
        Color(red: 0.96, green: 0.36, blue: 0.33),
        Color(red: 0.99, green: 0.67, blue: 0.28),
        Color(red: 0.39, green: 0.73, blue: 0.37),
        Color(red: 0.30, green: 0.63, blue: 0.87),
        Color(red: 0.59, green: 0.49, blue: 0.84),
        Color(red: 0.94, green: 0.55, blue: 0.74),
        Color(red: 0.38, green: 0.66, blue: 0.79),
        Color(red: 0.89, green: 0.53, blue: 0.33)
    ]

    static func color(for device: FidoPassCore.FidoDevice) -> Color {
        let seed = device.identitySeed.lowercased()
        var hash: UInt64 = 1469598103934665603
        for scalar in seed.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash &*= 1099511628211
        }
        let index = Int(hash % UInt64(palette.count))
        return palette[index]
    }
}

private extension View {
    func cardDecoration(cornerRadius: CGFloat = 14) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.08))
            )
    }
}

private struct StatusBanner: View {
    let icon: String?
    let color: Color
    let message: String
    let showsProgress: Bool

    var body: some View {
        HStack(spacing: 12) {
            if showsProgress {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(color)
            } else if let icon {
                Image(systemName: icon)
                    .foregroundColor(color)
            }
            Text(message)
                .font(.callout)
                .foregroundColor(.primary)
                .multilineTextAlignment(.leading)
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(color.opacity(0.28))
        )
    }
}

private struct SectionCard<Content: View>: View {
    let icon: String
    let title: String
    let accent: Color
    let subtitle: String?
    let trailing: AnyView?
    let content: Content

    init(icon: String,
         title: String,
         accent: Color = .accentColor,
         subtitle: String? = nil,
         trailing: AnyView? = nil,
         @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.accent = accent
        self.subtitle = subtitle
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(accent)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .textSelection(.enabled)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let trailing {
                    trailing
                }
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .cardDecoration()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AccountSummarySection: View {
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

private struct PasswordResultSection: View {
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
                                      ContentView.copyToPasteboard(password)
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

private struct DeviceAvatarView: View {
    let device: FidoPassCore.FidoDevice
    let isLocked: Bool

    var body: some View {
        let circleColor = isLocked ? Color.secondary.opacity(0.14) : Color.green.opacity(0.18)
        let symbolColor = isLocked ? Color.secondary : Color.green
        Circle()
            .fill(circleColor)
            .frame(width: 38, height: 38)
            .overlay(
                Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(symbolColor)
            )
            .accessibilityHidden(true)
    }
}

private struct ToastHostView: View {
    let toast: AccountsViewModel.ToastMessage?

    var body: some View {
        Group {
            if let toast {
                ToastView(toast: toast)
                    .frame(maxWidth: 480)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

private struct ToastView: View {
    let toast: AccountsViewModel.ToastMessage

    private var tintColor: Color {
        switch toast.style {
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon = toast.icon {
                Image(systemName: icon)
                    .symbolVariant(.fill)
                    .font(.title3)
                    .foregroundColor(tintColor)
                    .frame(width: 28, height: 28)
                    .background(tintColor.opacity(0.12), in: Circle())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.headline)
                    .foregroundColor(.primary)
                if let subtitle = toast.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(tintColor)
                .frame(width: 4)
                .padding(.vertical, 10)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 12)
    }
}

private struct AccountDetailView: View {
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
                    viewModel.showToast("Master key exported", icon: "square.and.arrow.down", style: .warning, subtitle: "Revealed in the password field")
                }
            } catch {
                await MainActor.run { viewModel.errorMessage = error.localizedDescription }
            }
        }
    }

private struct PasswordGenerationSection: View {
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

    private struct PortableAccountSection: View {
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

    private var accountAccent: Color {
        guard let path = account.devicePath,
              let device = viewModel.deviceStates[path]?.device else { return .accentColor }
        return DeviceColorPalette.color(for: device)
    }
}

private struct LabelInputView: View {
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
            .keyboardShortcut(.return, modifiers: [.command])

            Button(action: onGenerateAndCopy) {
                Label("Generate and copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Generate and copy immediately (hidden)")
            .disabled(!canSubmit)
            .keyboardShortcut("c", modifiers: [.command, .shift])

            if isGenerating { ProgressView().controlSize(.small) }
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
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
    }
}

struct NewAccountView: View {
    @EnvironmentObject var vm: AccountsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var accountId = ""
    @State private var mode: AccountMode = .standard
    @State private var importedKeyB64 = ""
    @State private var keyError: String? = nil
    @FocusState private var focused: Field?

    private enum Field { case account }
    private enum AccountMode: String, CaseIterable, Identifiable {
        case standard
        case portable

        var id: AccountMode { self }
        var title: String {
            switch self {
            case .standard: return "Standard"
            case .portable: return "Portable"
            }
        }
        var description: String {
            switch self {
            case .standard: return "Credential stored on this device"
            case .portable: return "fidopass.portable (import/export)"
            }
        }
    }

    private var isPortable: Bool { mode == .portable }
    private var trimmedAccountId: String { accountId.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var selectedDevice: FidoPassCore.FidoDevice? {
        guard let path = vm.selectedDevicePath else { return nil }
        return vm.devices.first(where: { $0.path == path })
    }
    private var selectedDeviceState: AccountsViewModel.DeviceState? {
        guard let path = selectedDevice?.path else { return nil }
        return vm.deviceStates[path]
    }
    private var deviceAccent: Color {
        if let state = selectedDeviceState {
            return state.unlocked ? DeviceColorPalette.color(for: state.device) : .orange
        }
        return .accentColor
    }

    private var isWaiting: Bool {
        if case .waiting = vm.enrollmentPhase { return true }
        return false
    }

    private var waitingMessage: String? {
        if case .waiting(let message) = vm.enrollmentPhase { return message }
        return nil
    }

    private var keyTouchPromptConfiguration: KeyTouchPromptConfiguration? {
        guard let waitingMessage else { return nil }
        let accessory: KeyTouchPromptConfiguration.Accessory?
        if let device = selectedDevice {
            accessory = .deviceName(device.displayName)
        } else {
            accessory = nil
        }
        return KeyTouchPromptConfiguration(title: waitingMessage,
                                           message: "Keep touching the security key until confirmation completes.",
                                           accent: deviceAccent,
                                           accessory: accessory)
    }

    private var failureMessage: (icon: String, color: Color, text: String)? {
        if case .failure(let message) = vm.enrollmentPhase {
            return (icon: "exclamationmark.triangle.fill", color: .orange, text: message)
        }
        return nil
    }

    var body: some View {
        KeyTouchPromptContainer(configuration: keyTouchPromptConfiguration) {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                deviceSection
                accountSection
                if isPortable {
                    portableSection
                }
                if let failure = failureMessage {
                    StatusBanner(icon: failure.icon,
                                 color: failure.color,
                                 message: failure.text,
                                 showsProgress: false)
                }
                actionBar
            }
            .padding(24)
            .frame(minWidth: 420)
            .disabled(isWaiting)
        }
        .onAppear {
            vm.resetEnrollmentState()
            DispatchQueue.main.async { focused = .account }
        }
        .onDisappear { vm.resetEnrollmentState() }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Create new account")
                .font(.title2.weight(.semibold))
            Text("Provide an identifier and choose how the credential should be stored on your security key.")
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }

    private var deviceSection: some View {
        SectionCard(icon: selectedDevice == nil ? "key.slash" : "key.fill",
                    title: deviceTitle,
                    accent: deviceAccent,
                    subtitle: deviceSubtitle,
                    trailing: deviceBadge) {
            if let device = selectedDevice {
                VStack(alignment: .leading, spacing: 12) {
                    InfoRow(icon: "number", title: "Identifier", value: device.identityLabel, accent: deviceAccent)
                    InfoRow(icon: "usb.cable", title: "Path", value: device.path, accent: deviceAccent)
                }
            } else if vm.devices.isEmpty {
                Text("Connect a FIDO security key to start enrolling accounts.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                Text("Select an unlocked device from the sidebar before adding a new account.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var accountSection: some View {
        SectionCard(icon: "person.badge.key",
                    title: "Account details",
                    accent: .accentColor,
                    subtitle: "Identifier is displayed in the sidebar and must be unique per key") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Account ID")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("example@service", text: $accountId)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .account)
                        .submitLabel(.done)
                        .onSubmit(create)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Credential type")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("Credential type", selection: $mode) {
                        ForEach(AccountMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(mode.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var portableSection: some View {
        SectionCard(icon: "arrow.triangle.2.circlepath",
                    title: "Portable credential",
                    accent: .orange,
                    subtitle: "Optional ImportedKey for fidopass.portable") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Use an existing ImportedKey to keep passwords consistent between keys. Leave blank to generate a fresh key when creating the account.")
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
    }

    private var actionBar: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { closeSheet() }
                .keyboardShortcut(.cancelAction)
            Button(action: create) {
                HStack(spacing: 8) {
                    if isWaiting {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    }
                    Text(isWaiting ? "Waiting…" : "Create")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCreate)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var canCreate: Bool {
        guard !trimmedAccountId.isEmpty,
              let state = selectedDeviceState,
              state.unlocked,
              !isWaiting
        else { return false }

        if isPortable {
            if importedKeyB64.isEmpty { return true }
            return keyError == nil && Data(base64Encoded: importedKeyB64)?.count == 32
        }
        return true
    }

    private var deviceTitle: String {
        if let device = selectedDevice { return device.displayName }
        if vm.devices.isEmpty { return "No security key connected" }
        return "No device selected"
    }

    private var deviceSubtitle: String {
        if let device = selectedDevice {
            if let state = selectedDeviceState, !state.unlocked {
                return "Locked – unlock from the sidebar to enroll"
            }
            return device.identityLabel
        }
        if vm.devices.isEmpty { return "Connect a FIDO key via USB or NFC" }
        return "Choose an unlocked key from the sidebar"
    }

    private var deviceBadge: AnyView? {
        guard let state = selectedDeviceState else { return nil }
        let text = state.unlocked ? "Unlocked" : "Locked"
        let color: Color = state.unlocked ? .green : .orange
        return AnyView(
            Text(text)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(color.opacity(0.18)))
                .foregroundColor(color)
        )
    }

    private func validateKey() {
        guard !importedKeyB64.isEmpty else { keyError = nil; return }
        if let data = Data(base64Encoded: importedKeyB64), data.count == 32 {
            keyError = nil
        } else {
            keyError = "Requires 32-byte base64 value"
        }
    }

    private func create() {
        guard canCreate else { return }
        let identifier = trimmedAccountId
        if isPortable {
            vm.enrollPortable(accountId: identifier, importedKeyB64: importedKeyB64.isEmpty ? nil : importedKeyB64)
        } else {
            vm.enroll(accountId: identifier)
        }
    }

    private func closeSheet() {
        vm.showNewAccountSheet = false
        vm.resetEnrollmentState()
        dismiss()
    }

}
