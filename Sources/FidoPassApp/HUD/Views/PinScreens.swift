import SwiftUI
import FidoPassCore

/// Giving a key its first PIN.
///
/// This screen exists because without it a brand-new key is a brick inside FidoPass: the app
/// would send the user to the PIN field, the key would answer `FIDO_ERR_PIN_NOT_SET`, and the
/// resulting message advised setting a PIN with no way to do so.
struct SetPINView: View {
    @ObservedObject var store: HUDStore
    @FocusState private var newFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HUDScreenHeader(title: "Set a PIN", subtitle: store.selectedDevice?.displayName) {
                store.backToAccounts()
            }

            VStack(alignment: .leading, spacing: 9) {
                HUDWarningBox(title: "This PIN belongs to the key, not to FidoPass",
                              message: "It is not your Mac password and it cannot be reset. Eight wrong entries in a row lock the key permanently, and every account on it goes with it. Choose something you will not have to guess at.")

                SecureField("New PIN", text: $store.pinForm.new)
                    .textFieldStyle(.roundedBorder)
                    .focused($newFocused)

                // A typo in a single field would produce a key whose PIN its owner does not
                // know — which is a dead key. That is what the second field is for.
                SecureField("Repeat PIN", text: $store.pinForm.confirm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await store.setInitialPIN() } }

                PinRuleFooter(store: store, forChange: false)

                HStack {
                    Spacer()
                    Button("Set PIN") { Task { await store.setInitialPIN() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!store.canSubmitPinForm(forChange: false))
                }
            }
            .padding(.horizontal, HUDMetrics.padding)
            .padding(.bottom, 12)
        }
        .onAppear {
            newFocused = true
            KeyboardLayoutService.preferEnglishLayoutIfNeeded()
        }
    }
}

/// Replacing the PIN.
struct ChangePINView: View {
    @ObservedObject var store: HUDStore
    @ObservedObject var devices: DeviceStore
    @FocusState private var currentFocused: Bool

    private var forced: Bool { devices.selectedState?.forcePINChange == true }
    private var retries: Int? { devices.selectedState?.pinRetriesRemaining }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HUDScreenHeader(title: "Change PIN", subtitle: store.selectedDevice?.displayName) {
                guard !forced else { return }
                store.pinForm.clear()
                store.backToAccounts()
            }

            VStack(alignment: .leading, spacing: 9) {
                if forced {
                    HUDWarningBox(title: "This key requires a new PIN",
                                  message: "It will refuse everything else until the PIN is changed.")
                }

                // Stated here, where the fear lives: people expect a PIN change to invalidate
                // what the key produces. It does not — the PIN opens the key, it is not an
                // input to the derivation.
                Text("Your passwords will not change. The PIN opens the key; it is not part of how passwords are derived.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SecureField("Current PIN", text: $store.pinForm.current)
                    .textFieldStyle(.roundedBorder)
                    .focused($currentFocused)
                SecureField("New PIN", text: $store.pinForm.new)
                    .textFieldStyle(.roundedBorder)
                SecureField("Repeat new PIN", text: $store.pinForm.confirm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await store.changePIN() } }

                PinRuleFooter(store: store, forChange: true)
                if let retries { PinAttemptsLabel(remaining: retries) }

                HStack {
                    Spacer()
                    if !forced {
                        Button("Cancel") {
                            store.pinForm.clear()
                            store.backToAccounts()
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                    Button("Change PIN") { Task { await store.changePIN() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!store.canSubmitPinForm(forChange: true))
                }
            }
            .padding(.horizontal, HUDMetrics.padding)
            .padding(.bottom, 12)
        }
        .onAppear {
            currentFocused = true
            KeyboardLayoutService.preferEnglishLayoutIfNeeded()
        }
    }
}

/// The rule being broken, or the rule to satisfy.
///
/// One line that changes rather than two that compete: showing the requirement and the
/// complaint at once makes the reader work out which one applies to them.
private struct PinRuleFooter: View {
    @ObservedObject var store: HUDStore
    let forChange: Bool

    var body: some View {
        if let issue = store.pinFormIssue(forChange: forChange) {
            Text(issue)
                .font(.caption2)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("At least \(store.pinPolicy.minLengthBytes) characters, at most \(PinPolicy.maxLengthBytes) bytes.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
