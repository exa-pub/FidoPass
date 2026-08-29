import SwiftUI
import FidoPassCore

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
                    AppActivationService.activate()
                    #endif
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New account") { accountsVM.showNewAccountSheet = true }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("Encrypt text…") { accountsVM.openCryptoEditor() }
                    .keyboardShortcut("e", modifiers: [.command])
                    .disabled(accountsVM.selected == nil || accountsVM.labelInput.isEmpty)
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

        // Declared after the main window on purpose: SwiftUI opens the first scene at
        // launch, and that has to be the account list, not the editor.
        //
        // A standalone window rather than a sheet — the editor is meant to sit beside the
        // application you are copying text into, which a modal cannot do.
        Window("Encrypt text", id: CryptoEditorSession.windowId) {
            CryptoEditorWindowView()
                .environmentObject(accountsVM)
        }
        .defaultSize(width: 820, height: 440)
    }
}