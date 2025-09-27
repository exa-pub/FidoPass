import SwiftUI
import FidoPassCore

struct AccountColumnView: View {
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
        } else if let path = viewModel.selectedDevicePath,
                  let state = viewModel.deviceStates[path] {
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

struct AccountColumnHeader: View {
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
        guard let path = viewModel.selectedDevicePath,
              let state = viewModel.deviceStates[path] else { return "Select a device on the left" }
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
            return account.id.localizedCaseInsensitiveContains(query)
            || account.rpId.localizedCaseInsensitiveContains(query)
        }
    }

    private var canCreateAccount: Bool {
        guard let path = viewModel.selectedDevicePath,
              let state = viewModel.deviceStates[path] else { return false }
        return state.unlocked
    }
}

struct SearchField: View {
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
