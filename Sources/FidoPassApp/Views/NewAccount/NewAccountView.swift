import SwiftUI
import FidoPassCore

struct NewAccountView: View {
    @EnvironmentObject var vm: AccountsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var accountId = ""
    @State private var mode: AccountMode = .standard
    @State private var importedKeyB64 = ""
    @State private var keyError: String? = nil
    @FocusState private var focused: Field?

    private enum Field { case account }
    private enum AccountMode: String, CaseIterable, Identifiable {
        case standard
        case portable

        var id: AccountMode { self }
        var title: String {
            switch self {
            case .standard: return "Standard"
            case .portable: return "Portable"
            }
        }
        var description: String {
            switch self {
            case .standard: return "Credential stored on this device"
            case .portable: return "fidopass.portable (import/export)"
            }
        }
    }

    private var isPortable: Bool { mode == .portable }
    private var trimmedAccountId: String { accountId.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var selectedDevice: FidoDevice? {
        guard let path = vm.selectedDevicePath else { return nil }
        return vm.devices.first(where: { $0.path == path })
    }
    private var selectedDeviceState: AccountsViewModel.DeviceState? {
        guard let path = selectedDevice?.path else { return nil }
        return vm.deviceStates[path]
    }
    private var deviceAccent: Color {
        if let state = selectedDeviceState {
            return state.unlocked ? DeviceColorPalette.color(for: state.device) : .orange
        }
        return .accentColor
    }

    private var isWaiting: Bool {
        if case .waiting = vm.enrollmentPhase { return true }
        return false
    }

    private var waitingMessage: String? {
        if case .waiting(let message) = vm.enrollmentPhase { return message }
        return nil
    }

    private var keyTouchPromptConfiguration: KeyTouchPromptConfiguration? {
        guard let waitingMessage else { return nil }
        let accessory: KeyTouchPromptConfiguration.Accessory?
        if let device = selectedDevice {
            accessory = .deviceName(device.displayName)
        } else {
            accessory = nil
        }
        return KeyTouchPromptConfiguration(title: waitingMessage,
                                           message: "Keep touching the security key until confirmation completes.",
                                           accent: deviceAccent,
                                           accessory: accessory)
    }

    private var failureMessage: (icon: String, color: Color, text: String)? {
        if case .failure(let message) = vm.enrollmentPhase {
            return (icon: "exclamationmark.triangle.fill", color: .orange, text: message)
        }
        return nil
    }

    var body: some View {
        KeyTouchPromptContainer(configuration: keyTouchPromptConfiguration) {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                deviceSection
                accountSection
                if isPortable {
                    portableSection
                }
                if let failure = failureMessage {
                    StatusBanner(icon: failure.icon,
                                 color: failure.color,
                                 message: failure.text,
                                 showsProgress: false)
                }
                actionBar
            }
            .padding(24)
            .frame(minWidth: 420)
            .disabled(isWaiting)
        }
        .onAppear {
            vm.resetEnrollmentState()
            DispatchQueue.main.async { focused = .account }
        }
        .onDisappear { vm.resetEnrollmentState() }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Create new account")
                .font(.title2.weight(.semibold))
            Text("Provide an identifier and choose how the credential should be stored on your security key.")
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }

    private var deviceSection: some View {
        SectionCard(icon: selectedDevice == nil ? "key.slash" : "key.fill",
                    title: deviceTitle,
                    accent: deviceAccent,
                    subtitle: deviceSubtitle,
                    trailing: deviceBadge) {
            if let device = selectedDevice {
                VStack(alignment: .leading, spacing: 12) {
                    InfoRow(icon: "number", title: "Identifier", value: device.identityLabel, accent: deviceAccent)
                    InfoRow(icon: "usb.cable", title: "Path", value: device.path, accent: deviceAccent)
                }
            } else if vm.devices.isEmpty {
                Text("Connect a FIDO security key to start enrolling accounts.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                Text("Select an unlocked device from the sidebar before adding a new account.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var accountSection: some View {
        SectionCard(icon: "person.badge.key",
                    title: "Account details",
                    accent: .accentColor,
                    subtitle: "Identifier is displayed in the sidebar and must be unique per key") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Account ID")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("example@service", text: $accountId)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .account)
                        .submitLabel(.done)
                        .onSubmit(create)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Credential type")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("Credential type", selection: $mode) {
                        ForEach(AccountMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(mode.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var portableSection: some View {
        SectionCard(icon: "arrow.triangle.2.circlepath",
                    title: "Portable credential",
                    accent: .orange,
                    subtitle: "Optional ImportedKey for fidopass.portable") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Use an existing ImportedKey to keep passwords consistent between keys. Leave blank to generate a fresh key when creating the account.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Base64 ImportedKey", text: $importedKeyB64)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: importedKeyB64) { _ in validateKey() }
                if let keyError {
                    Text(keyError)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { closeSheet() }
                .keyboardShortcut(.cancelAction)
            Button(action: create) {
                HStack(spacing: 8) {
                    if isWaiting {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    }
                    Text(isWaiting ? "Waiting…" : "Create")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCreate)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var canCreate: Bool {
        guard !trimmedAccountId.isEmpty,
              let state = selectedDeviceState,
              state.unlocked,
              !isWaiting else { return false }

        if isPortable {
            if importedKeyB64.isEmpty { return true }
            return keyError == nil && Data(base64Encoded: importedKeyB64)?.count == 32
        }
        return true
    }

    private var deviceTitle: String {
        if let device = selectedDevice { return device.displayName }
        if vm.devices.isEmpty { return "No security key connected" }
        return "No device selected"
    }

    private var deviceSubtitle: String {
        if let device = selectedDevice {
            if let state = selectedDeviceState, !state.unlocked {
                return "Locked – unlock from the sidebar to enroll"
            }
            return device.identityLabel
        }
        if vm.devices.isEmpty { return "Connect a FIDO key via USB or NFC" }
        return "Choose an unlocked key from the sidebar"
    }

    private var deviceBadge: AnyView? {
        guard let state = selectedDeviceState else { return nil }
        let text = state.unlocked ? "Unlocked" : "Locked"
        let color: Color = state.unlocked ? .green : .orange
        return AnyView(
            Text(text)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(color.opacity(0.18)))
                .foregroundColor(color)
        )
    }

    private func validateKey() {
        guard !importedKeyB64.isEmpty else { keyError = nil; return }
        if let data = Data(base64Encoded: importedKeyB64), data.count == 32 {
            keyError = nil
        } else {
            keyError = "Requires 32-byte base64 value"
        }
    }

    private func create() {
        guard canCreate else { return }
        let identifier = trimmedAccountId
        if isPortable {
            vm.enrollPortable(accountId: identifier, importedKeyB64: importedKeyB64.isEmpty ? nil : importedKeyB64)
        } else {
            vm.enroll(accountId: identifier)
        }
    }

    private func closeSheet() {
        vm.showNewAccountSheet = false
        vm.resetEnrollmentState()
        dismiss()
    }
}
