import SwiftUI
import FidoPassCore

struct PanelHeaderView: View {
    @ObservedObject var store: PanelStore
    @ObservedObject var devices: DeviceStore
    @ObservedObject var accounts: AccountStore

    var body: some View {
        HStack(spacing: 9) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                if devices.devices.count > 1 {
                    keySwitcher
                } else {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            if store.isSelectedKeyUnlocked {
                Button(action: store.lockSelectedKey) {
                    Image(systemName: "lock.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Lock this key now (⌘L)")
            }

            Menu {
                Button("New account…") { store.show(.enroll) }
                    .disabled(!store.isSelectedKeyUnlocked)
                Button("Manage this key…") { store.openManager() }
                    .disabled(devices.devices.isEmpty)
                Button("Refresh") { Task { await store.refresh() } }
                Divider()
                // Sealing needs no key at all; opening needs the selected one, unlocked.
                Button("Encrypt a message…") { store.openEncryptor() }
                Button("Decrypt a message…") { store.openDecryptor() }
                    .disabled(!store.isSelectedKeyUnlocked)
                Divider()
                Button("Lock now") { store.lockSelectedKey() }
                    .disabled(!store.isSelectedKeyUnlocked)
                Divider()
                Button("Preferences…") { store.openPreferences() }
                #if FIDOPASS_VIRTUAL_KEYS
                Button("Virtual Devices…") { store.openVirtualDevices() }
                #endif
                Button("Quit FidoPass") { store.quit() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Key and application actions")
        }
        .padding(.horizontal, PanelMetrics.padding)
        .padding(.vertical, 9)
    }

    private var avatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.16))
                .frame(width: 28, height: 28)
            Image(systemName: store.isSelectedKeyUnlocked ? "key.fill" : "key.slash.fill")
                .font(.system(size: 12))
                .foregroundStyle(tint)
        }
    }

    private var tint: Color {
        guard let device = store.selectedDevice else { return .secondary }
        return store.isSelectedKeyUnlocked ? DeviceColorPalette.color(for: device) : .orange
    }

    private var title: String {
        store.selectedDevice?.displayName ?? "No security key"
    }

    private var subtitle: String {
        guard let device = store.selectedDevice else { return "Connect a key over USB or NFC" }
        guard store.isSelectedKeyUnlocked else { return "Locked — PIN required" }
        let count = accounts.accounts(onDevice: device.path).count
        return count == 1 ? "Unlocked · 1 account" : "Unlocked · \(count) accounts"
    }

    private var keySwitcher: some View {
        Picker("Security key", selection: Binding(get: { devices.selectedPath ?? "" }, set: { store.selectKey(path: $0) })) {
            ForEach(devices.devices, id: \.path) { device in
                Text("\(device.displayName) · \(devices.state(for: device.path)?.unlocked == true ? "Unlocked" : "Locked")")
                    .tag(device.path)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .help("Choose the key for this HUD. \(store.selectedDevice?.identityLabel ?? "")")
    }
}
