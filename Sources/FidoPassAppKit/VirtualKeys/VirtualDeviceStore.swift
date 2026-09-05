import Foundation
import FidoPassCore
import FidoPassVirtualKeys

@MainActor
final class VirtualDeviceStore: ObservableObject {
    @Published private(set) var devices: [VirtualDevice] = []
    @Published private(set) var adding = false
    @Published private(set) var pending: Set<UUID> = []
    @Published private(set) var error: PresentedError?
    let helperAvailable: Bool

    private let registry: VirtualDeviceRegistry
    private weak var deviceStore: DeviceStore?
    private var revision: UInt64 = 0
    private var connectedDevices: [FidoDevice] = []

    init(registry: VirtualDeviceRegistry, devices: DeviceStore, executable: URL) {
        self.registry = registry
        self.deviceStore = devices
        self.helperAvailable = FileManager.default.isExecutableFile(atPath: executable.path)
        if !helperAvailable { error = PresentedError(VirtualKeyError.helperMissing) }
        registry.observe { [weak self] snapshot in
            Task { @MainActor in self?.apply(snapshot) }
        }
    }

    private func apply(_ snapshot: VirtualDeviceSnapshot) {
        guard snapshot.revision > revision else { return }
        revision = snapshot.revision
        devices = snapshot.devices
        if connectedDevices != snapshot.connectedDevices {
            connectedDevices = snapshot.connectedDevices
            deviceStore?.replaceConnectedDevices(connectedDevices)
        }
    }

    func add(profile: OpenSKHostClient.Profile) async {
        guard helperAvailable, !adding else { return }
        adding = true
        error = nil
        defer { adding = false; apply(registry.snapshot) }
        do {
            let registry = registry
            _ = try await Task.detached { try registry.add(profile: profile) }.value
        } catch { self.error = PresentedError(error) }
    }

    func toggleConnection(_ device: VirtualDevice) async {
        let registry = registry
        await perform(id: device.id) {
            if device.connection == .connected { try registry.disconnect(id: device.id) }
            else { try registry.attach(id: device.id) }
        }
    }

    func remove(_ device: VirtualDevice) async {
        let registry = registry
        await perform(id: device.id) { try registry.remove(id: device.id) }
    }

    func touch(_ device: VirtualDevice) async {
        guard let touch = device.touch else { return }
        let registry = registry
        // Do not gate disconnect on a touch write; both are out-of-band controls.
        do { try await Task.detached { try registry.touch(id: device.id, expected: touch) }.value }
        catch { self.error = PresentedError(error) }
    }

    private func perform(id: UUID, operation: @escaping @Sendable () throws -> Void) async {
        guard !pending.contains(id) else { return }
        pending.insert(id)
        error = nil
        defer { pending.remove(id); apply(registry.snapshot) }
        do { try await Task.detached(operation: operation).value }
        catch { self.error = PresentedError(error) }
    }
}
