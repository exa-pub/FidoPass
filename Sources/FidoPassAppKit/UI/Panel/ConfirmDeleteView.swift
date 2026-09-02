import SwiftUI
import FidoPassCore

struct ConfirmDeleteView: View {
    @ObservedObject var store: HUDStore
    let ref: AccountRef

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HUDScreenHeader(title: "Delete account", subtitle: ref.accountId) { store.backToAccounts() }

            VStack(alignment: .leading, spacing: 9) {
                HUDWarningBox(title: "No way back",
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
            .padding(.horizontal, HUDMetrics.padding)
            .padding(.bottom, 12)
        }
    }
}
