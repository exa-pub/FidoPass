import SwiftUI
import FidoPassVirtualKeys

struct VirtualDevicesView: View {
    @ObservedObject var store: VirtualDeviceStore
    @State private var profile: OpenSKHostClient.Profile = .standard
    @State private var removing: VirtualDevice?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Profile", selection: $profile) {
                    ForEach(OpenSKHostClient.Profile.allCases, id: \.rawValue) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .frame(maxWidth: 240)
                Spacer()
                Button(store.adding ? "Adding…" : "Add device", systemImage: "plus") {
                    Task { await store.add(profile: profile) }
                }
                .disabled(!store.helperAvailable || store.adding)
                .accessibilityIdentifier("virtual.add")
            }
            if store.devices.isEmpty {
                ContentUnavailableView("No virtual devices", systemImage: "key",
                                       description: Text("Add an OpenSK device, then set its PIN in the HUD."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.devices) { device in row(device) }
                    }
                }
            }
            if let error = store.error {
                Text(error.fullText()).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Text("Virtual keys. State is lost when the app quits.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 280)
        .alert("Remove virtual device?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) {
                if let device = removing { Task { await store.remove(device) } }
                removing = nil
            }
        } message: {
            Text("This deletes the device and all its accounts. It cannot be undone.")
        }
    }

    private func row(_ device: VirtualDevice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "key.fill").foregroundStyle(device.touch == nil ? Color.secondary : Color.accentColor)
                Text(device.name).font(.headline)
                Text(device.profile.title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(device.touch == nil ? device.connection.rawValue : "Waiting for touch")
                    .font(.callout).foregroundStyle(device.touch == nil ? Color.secondary : Color.accentColor)
            }
            HStack {
                Button("Touch", systemImage: "hand.tap") { Task { await store.touch(device) } }
                    .disabled(device.touch == nil || store.pending.contains(device.id))
                    .accessibilityIdentifier("virtual.touch.\(device.name)")
                Spacer()
                Button(device.connection == .connected ? "Disconnect" : "Connect") {
                    Task { await store.toggleConnection(device) }
                }
                .disabled(store.pending.contains(device.id) || ![.connected, .disconnected].contains(device.connection))
                .accessibilityIdentifier("virtual.connect.\(device.name)")
                Button("Remove", role: .destructive) { removing = device }
                    .disabled(store.pending.contains(device.id) || [.connecting, .disconnecting].contains(device.connection))
                    .accessibilityIdentifier("virtual.remove.\(device.name)")
            }
            if let failure = device.failure {
                Text(failure.localizedDescription).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
