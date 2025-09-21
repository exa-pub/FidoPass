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
        .commands { // basic commands for refresh
            CommandGroup(replacing: .newItem) {
                Button("Новая учётка") { accountsVM.showNewAccountSheet = true }
                    .keyboardShortcut("n", modifiers: [.command])
            }
        }
    }
}
