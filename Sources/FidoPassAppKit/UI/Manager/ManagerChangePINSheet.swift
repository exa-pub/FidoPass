import SwiftUI
import FidoPassCore

/// Replacing the key's PIN.
///
/// Lives in the manager rather than the panel: it is a rare, deliberate operation on the key
/// itself, which is what this window is for. It works on a locked key — proving knowledge of
/// the old PIN is the same proof unlocking asks for — and on a key that is demanding a change,
/// which is the one case where the user has no choice but to be here.
struct ManagerChangePINSheet: View {
    @ObservedObject var store: HUDStore
    @ObservedObject var devices: DeviceStore
    let onClose: () -> Void

    @FocusState private var currentFocused: Bool

    private var forced: Bool { devices.selectedState?.forcePINChange == true }
    private var retries: Int? { devices.selectedState?.pinRetriesRemaining }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change PIN").font(.system(size: 15, weight: .semibold))

            if forced {
                Label("This key requires a new PIN. It will refuse everything else until the PIN is changed.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Stated here, where the fear lives: people expect a PIN change to invalidate what
            // the key produces. It does not — the PIN opens the key, it is not an input to the
            // derivation.
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
                .onSubmit(submit)

            PinRuleFooter(store: store, forChange: true)
            if let retries { PinAttemptsLabel(remaining: retries) }
            if let error = store.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    store.pinForm.clear()
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                Button("Change PIN", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.canSubmitPinForm(forChange: true) || store.isWorking)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            currentFocused = true
            KeyboardLayoutService.preferEnglishLayoutIfNeeded()
        }
    }

    private func submit() {
        Task {
            await store.changePIN()
            // Only leave once the key has accepted it: a wrong old PIN costs one of the eight
            // attempts, and closing the sheet would hide the count that says so.
            if store.errorText == nil, store.pinForm.isEmpty { onClose() }
        }
    }
}
