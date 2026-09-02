import SwiftUI
import FidoPassCore

/// Giving a key its first PIN.
///
/// This screen exists because without it a brand-new key is a brick inside FidoPass: the app
/// would send the user to the PIN field, the key would answer `FIDO_ERR_PIN_NOT_SET`, and the
/// resulting message advised setting a PIN with no way to do so.
struct SetPINView: View {
    @ObservedObject var store: HUDStore
    @ObservedObject private var form: PinFormModel

    init(store: HUDStore) {
        self.store = store
        self.form = store.pinForm
    }

    private enum Field: Hashable { case new, confirm }
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HUDScreenHeader(title: "Set a PIN", subtitle: store.selectedDevice?.displayName) {
                store.backToAccounts()
            }

            VStack(alignment: .leading, spacing: 9) {
                HUDWarningBox(title: "This PIN belongs to the key, not to FidoPass",
                              message: "It is not your Mac password and it cannot be reset. Eight wrong entries in a row lock the key permanently, and every account on it goes with it. Choose something you will not have to guess at.")

                SecureField("New PIN", text: $form.new)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .new)

                // A typo in a single field would produce a key whose PIN its owner does not
                // know — which is a dead key. That is what the second field is for.
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
            .padding(.horizontal, HUDMetrics.padding)
            .padding(.bottom, 12)
        }
        .tabFocusChain([Field.new, .confirm], focus: $focus)
        .onAppear {
            focus = .new
            KeyboardLayoutService.preferEnglishLayoutIfNeeded()
        }
    }
}
