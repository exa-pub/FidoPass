import SwiftUI
import FidoPassCore

struct UnlockPromptView: View {
    @ObservedObject var viewModel: AccountsViewModel
    let device: FidoDevice

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("\(device.displayName) is locked")
                .font(.headline)
            Text("Enter the PIN to unlock the device and view accounts.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            PinUnlockRow(viewModel: viewModel, device: device)
            if let remaining = viewModel.deviceStates[device.path]?.pinRetriesRemaining {
                PinAttemptsWarning(remaining: remaining)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await viewModel.refreshPinRetries(for: device) }
    }
}

/// Shows how many PIN attempts remain before the key locks itself for good.
///
/// A FIDO2 authenticator stops accepting its PIN permanently after eight consecutive
/// failures, and nothing recovers it but a factory reset that wipes every credential. For
/// keys that derive vault passwords there is no way back from that, so the countdown is
/// stated plainly rather than left for the user to discover.
struct PinAttemptsWarning: View {
    let remaining: Int

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundColor(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(color.opacity(0.14)))
            .multilineTextAlignment(.center)
    }

    private var text: String {
        switch remaining {
        case 0:  return "Locked — no attempts left"
        case 1:  return "1 attempt left before this key locks permanently"
        default: return "\(remaining) attempts left"
        }
    }

    private var icon: String {
        remaining <= 1 ? "exclamationmark.triangle.fill" : "info.circle"
    }

    private var color: Color {
        switch remaining {
        case 0, 1: return .red
        case 2, 3: return .orange
        default:   return .secondary
        }
    }
}

struct PinUnlockRow: View {
    @ObservedObject var viewModel: AccountsViewModel
    let device: FidoDevice
    @FocusState private var pinFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            SecureField("PIN", text: Binding(get: {
                viewModel.deviceStates[device.path]?.pinDraft ?? ""
            }, set: { pin in
                var state = viewModel.deviceStates[device.path] ?? AccountsViewModel.DeviceState(device: device)
                state.pinDraft = pin
                viewModel.deviceStates[device.path] = state
            }))
            .textFieldStyle(.roundedBorder)
            .frame(width: 160)
            .onSubmit(attemptUnlock)
            .focused($pinFocused)

            Button {
                attemptUnlock()
            } label: {
                Label("Unlock", systemImage: "lock.open")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Unlock the device with the provided PIN")
            .disabled((viewModel.deviceStates[device.path]?.pinDraft ?? "").isEmpty)
        }
        .onChange(of: pinFocused) { isFocused in
            if isFocused {
                KeyboardLayoutService.preferEnglishLayoutIfNeeded()
            }
        }
        .onChange(of: device.path) { _ in
            DispatchQueue.main.async {
                pinFocused = true
                KeyboardLayoutService.preferEnglishLayoutIfNeeded()
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                pinFocused = true
                KeyboardLayoutService.preferEnglishLayoutIfNeeded()
            }
        }
    }

    private func attemptUnlock() {
        if let pin = viewModel.deviceStates[device.path]?.pinDraft, !pin.isEmpty {
            viewModel.unlockDevice(device, pin: pin)
        }
    }
}
