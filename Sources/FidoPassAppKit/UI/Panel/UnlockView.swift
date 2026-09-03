import SwiftUI
import FidoPassCore

/// PIN entry.
///
/// The field takes focus the moment the panel opens, so the whole "wake the HUD, unlock,
/// get the password" path can be typed without touching the mouse.
struct UnlockView: View {
    @ObservedObject var store: PanelStore
    @ObservedObject var devices: DeviceStore
    @FocusState private var pinFocused: Bool

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
        .padding(.horizontal, PanelMetrics.padding)
        .padding(.vertical, 12)
        .onAppear {
            pinFocused = true
            KeyboardLayoutService.preferEnglishLayoutIfNeeded()
        }
        .onChange(of: pinFocused) { _, focused in
            if focused { KeyboardLayoutService.preferEnglishLayoutIfNeeded() }
        }
        // Typing is asking: the first character reads the attempts left off a key nobody has
        // asked yet, so the count is on screen before an attempt is spent. See
        // `PanelStore.pinDraftDidChange` for why the screen appearing is not enough.
        .onChange(of: store.pinDraft) {
            Task { await store.pinDraftDidChange() }
        }
    }
}
