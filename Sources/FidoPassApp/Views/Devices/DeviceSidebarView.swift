import SwiftUI
import FidoPassCore

struct DeviceSidebarView: View {
    @ObservedObject var viewModel: AccountsViewModel

    var body: some View {
        List(selection: Binding(get: { viewModel.selectedDevicePath },
                                set: { viewModel.selectedDevicePath = $0 })) {
            Section {
                if viewModel.devices.isEmpty {
                    DeviceSidebarEmptyState()
                } else {
                    ForEach(viewModel.devices, id: \.path) { device in
                        DeviceSidebarRow(device: device,
                                         state: viewModel.deviceStates[device.path],
                                         accountCount: accountCount(for: device),
                                         onReload: { viewModel.reload() },
                                         onLock: { viewModel.lockDevice(device) })
                            .tag(device.path as String?)
                    }
                }
            } header: {
                Text("Devices")
                    .textCase(.uppercase)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 240)
        .listStyle(.sidebar)
    }

    private func accountCount(for device: FidoDevice) -> Int {
        viewModel.accounts.filter { $0.devicePath == device.path }.count
    }
}

struct DeviceSidebarEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No devices")
                .font(.headline)
            Text("Connect a FIDO key to manage accounts.")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 24)
    }
}

struct DeviceSidebarRow: View {
    let device: FidoDevice
    let state: AccountsViewModel.DeviceState?
    let accountCount: Int
    let onReload: () -> Void
    let onLock: () -> Void

    var body: some View {
        let unlocked = state?.unlocked == true
        let statusText = unlocked ? (accountCount == 0 ? "Ready, no accounts" : "Ready, \(accountCount)") : "PIN required"

        HStack(alignment: .center, spacing: 12) {
            DeviceAvatarView(device: device, isLocked: !unlocked)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .renderingMode(.template)
                        .symbolVariant(.fill)
                        .foregroundStyle(DeviceColorPalette.color(for: device))
                    Text(device.displayName)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(device.identityLabel)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()

            if unlocked {
                Text("\(accountCount)")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundColor(.accentColor)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
        .contextMenu {
            Button("Refresh", action: onReload)
            if unlocked { Button("Lock", action: onLock) }
        }
        .help(unlocked ? "Device is unlocked and ready" : "Device requires PIN")
    }
}
