import SwiftUI
import FidoPassCore

/// Manager PIN-change form, also available when the key requires a PIN change.
struct ManagerChangePINSheet: View {
    @ObservedObject var store: ManagerStore
    @ObservedObject private var form: PinFormModel
    @ObservedObject private var touchGate: TouchGate

    @FocusState private var currentFocused: Bool

    init(store: ManagerStore, touchGate: TouchGate) {
        self.store = store
        self.form = store.pinForm
        self.touchGate = touchGate
    }

    private var forced: Bool { store.keyState?.forcePINChange == true }
    private var retries: Int? { store.keyState?.pinRetriesRemaining }

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

            SecureField("Current PIN", text: $form.current)
                .textFieldStyle(.roundedBorder)
                .focused($currentFocused)
            SecureField("New PIN", text: $form.new)
                .textFieldStyle(.roundedBorder)
            SecureField("Repeat new PIN", text: $form.confirm)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)

            PinRuleFooter(form: form)
            if let retries { PinAttemptsLabel(remaining: retries) }
            if let error = store.pinError {
                Text(error.fullText(retriesRemaining: retries))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { store.cancelChangePIN() }
                    .keyboardShortcut(.cancelAction)
                Button("Change PIN", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.canSubmit || touchGate.isWorking)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            currentFocused = true
            KeyboardLayoutService.preferEnglishLayoutIfNeeded()
        }
    }

    /// The store closes the sheet itself once the key has accepted the PIN, and leaves it up
    /// otherwise: a wrong old PIN costs one of the eight attempts, and closing would hide the
    /// count that says so.
    private func submit() {
        Task { await store.changePIN() }
    }
}
