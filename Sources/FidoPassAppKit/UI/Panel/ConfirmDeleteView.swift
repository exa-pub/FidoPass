import SwiftUI
import FidoPassCore

struct ConfirmDeleteView: View {
    @ObservedObject var store: PanelStore
    let ref: AccountRef

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelScreenHeader(title: "Delete account", subtitle: ref.accountId) { store.backToAccounts() }

            VStack(alignment: .leading, spacing: 9) {
                PanelWarningBox(title: "No way back",
                              message: "“\(ref.accountId)” is erased from the key. Every password derived from it becomes unreachable, and a vault master password has no reset.",
                              tint: .red)
                HStack {
                    Spacer()
                    Button("Cancel") { store.backToAccounts() }
                        .keyboardShortcut(.cancelAction)
                    Button("Delete") { Task { await store.deleteAccount(ref) } }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(store.isWorking)
                }
            }
            .padding(.horizontal, PanelMetrics.padding)
            .padding(.bottom, 12)
        }
    }
}
