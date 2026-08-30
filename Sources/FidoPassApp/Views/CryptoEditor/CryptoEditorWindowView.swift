import SwiftUI

/// Contents of the editor window.
///
/// The window scene always exists; what it shows depends on whether a session is live. When
/// the session ends — the device locks, the PIN expires, the user closes it — the window
/// falls back to an explanation instead of silently holding a dead key.
struct CryptoEditorWindowView: View {
    @EnvironmentObject var vm: AccountsViewModel

    var body: some View {
        Group {
            if let session = vm.cryptoEditor {
                CryptoEditorView(session: session,
                                 onCopyPlaintext: { vm.copyGeneratedPassword($0) },
                                 onCopyCiphertext: { vm.copyEncryptedValue($0) })
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "lock.rectangle")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No editing session")
                        .font(.headline)
                    Text("Select an account in the main window and choose Encrypt text… (⌘E).")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDisappear { vm.closeCryptoEditor() }
    }
}
