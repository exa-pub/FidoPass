import SwiftUI
import FidoPassCore

/// PIN entry.
///
/// The field takes focus the moment the panel opens, so the whole "wake the HUD, unlock,
/// get the password" path can be typed without touching the mouse.
struct UnlockView: View {
    @ObservedObject var store: HUDStore
    @ObservedObject var devices: DeviceStore
    @FocusState private var pinFocused: Bool
    /// Reading the key's status opens it, and an opened key is seized from every other
    /// process. One read per appearance of this screen, and only once the user has started
    /// typing — see `askForStatus`.
    @State private var statusRequested = false

    private var retries: Int? { devices.selectedState?.pinRetriesRemaining }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let pending = store.pendingSummary {
                Text(pending)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Enter the key PIN. It is kept in memory for five minutes, then asked again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                SecureField("PIN", text: $store.pinDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($pinFocused)
                    .onSubmit { Task { await store.submitPin() } }
                Button("Unlock") { Task { await store.submitPin() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.pinDraft.isEmpty || store.isWorking)
            }

            if let retries { PinAttemptsLabel(remaining: retries) }
        }
        .padding(.horizontal, HUDMetrics.padding)
        .padding(.vertical, 12)
        .onAppear {
            pinFocused = true
            KeyboardLayoutService.preferEnglishLayoutIfNeeded()
        }
        .onChange(of: pinFocused) { focused in
            if focused { KeyboardLayoutService.preferEnglishLayoutIfNeeded() }
        }
        .onChange(of: store.pinDraft) { draft in
            if !draft.isEmpty { askForStatus() }
        }
    }
}

extension UnlockView {
    /// Asks the key how many attempts are left — on the first character typed, not when this
    /// screen appears.
    ///
    /// The screen appears the moment a key is plugged in, and opening a key seizes it
    /// (`libfido2/src/hid_osx.c`, `kIOHIDOptionsTypeSeizeDevice`). That is how a running
    /// FidoPass used to break `ykman fido reset`: the key was taken over within a second of
    /// being connected, before its owner had asked for anything. Typing a PIN is asking; the
    /// key being present is not. By the time a PIN is finished the count is on screen, which
    /// is where it matters — before the attempt is spent.
    fileprivate func askForStatus() {
        guard !statusRequested, let device = store.selectedDevice else { return }
        statusRequested = true
        Task { await devices.refreshStatus(for: device) }
    }
}
