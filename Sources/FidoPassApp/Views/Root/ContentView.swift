import SwiftUI

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
                           onReload: { vm.reload() })
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
}

struct ToolbarButtons: ToolbarContent {
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
