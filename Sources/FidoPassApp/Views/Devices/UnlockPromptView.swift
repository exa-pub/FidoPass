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
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PinUnlockRow: View {
    @ObservedObject var viewModel: AccountsViewModel
    let device: FidoDevice
    @FocusState private var pinFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            SecureField("PIN", text: Binding(get: {
                viewModel.deviceStates[device.path]?.pin ?? ""
            }, set: { pin in
                var state = viewModel.deviceStates[device.path] ?? AccountsViewModel.DeviceState(device: device)
                state.pin = pin
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
            .disabled((viewModel.deviceStates[device.path]?.pin ?? "").isEmpty)
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
        if let pin = viewModel.deviceStates[device.path]?.pin, !pin.isEmpty {
            viewModel.unlockDevice(device, pin: pin)
        }
    }
}
