import SwiftUI
import FidoPassCore
#if os(macOS)
import AppKit
#endif

@main
struct FidoPassApp: App {
    @StateObject private var accountsVM = AccountsViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(accountsVM)
                .onAppear {
                    accountsVM.reload()
                    #if os(macOS)
                    DispatchQueue.main.async {
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                        // make main window key & front
                        NSApp.windows.first?.makeKeyAndOrderFront(nil)
                    }
                    #endif
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New account") { accountsVM.showNewAccountSheet = true }
                    .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(after: .newItem) {
                Button("Reload data") { accountsVM.reload() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Search accounts") { accountsVM.requestSearchFocus() }
                    .keyboardShortcut("f", modifiers: [.command])
                    .disabled(accountsVM.devices.isEmpty)
                Button("Delete selected account") { accountsVM.requestDeleteSelectedAccount() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(accountsVM.selected == nil)
            }
        }
    }
}
