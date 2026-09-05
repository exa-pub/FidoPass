import SwiftUI
import FidoPassCore

/// Sets the initial PIN required before a new key can enroll accounts.
struct SetPINView: View {
    @ObservedObject var store: PanelStore
    @ObservedObject private var form: PinFormModel

    init(store: PanelStore) {
        self.store = store
        self.form = store.pinForm
    }

    private enum Field: Hashable { case new, confirm }
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelScreenHeader(title: "Set a PIN", subtitle: store.selectedDevice?.displayName) {
                store.backToAccounts()
            }

            VStack(alignment: .leading, spacing: 9) {
                PanelWarningBox(title: "This PIN belongs to the key, not to FidoPass",
                              message: "Choose a PIN for this security key. Too many wrong attempts block it. Resetting the key erases every account and does not recover its passwords.")

                SecureField("New PIN", text: $form.new)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .new)

                SecureField("Repeat PIN", text: $form.confirm)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .confirm)
                    .onSubmit { Task { await store.setInitialPIN() } }

                PinRuleFooter(form: form)

                HStack {
                    Spacer()
                    Button("Set PIN") { Task { await store.setInitialPIN() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!form.canSubmit)
                }
            }
            .padding(.horizontal, PanelMetrics.padding)
            .padding(.bottom, 12)
        }
        .tabFocusChain([Field.new, .confirm], focus: $focus)
        .onAppear {
            focus = .new
            KeyboardLayoutService.preferEnglishLayoutIfNeeded()
        }
    }
}
