import Foundation
import FidoPassCore
import FidoPassVirtualKeys

/// The lock protects fault queues and counters. Device lifecycle belongs to the shared registry.
package final class TestVirtualDeviceRegistry: DeviceListing, DeviceConnectionFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let registry: VirtualDeviceRegistry
    private var faults: [UUID: [AuthenticatorFault]] = [:]
    private var events: [UInt8] = []
    private var opens = 0
    private var closes = 0

    package init(count: Int = 1, profile: OpenSKHostClient.Profile = .standard, hid: Bool = false) throws {
        registry = VirtualDeviceRegistry(executable: OpenSKHostClient.executable, presence: .immediate,
                                         realtime: false, touchTimeoutMilliseconds: 5_000, hid: hid)
        for index in 0..<count {
            try registry.add(profile: profile, seed: Data(repeating: UInt8(index + 1), count: 32))
        }
    }

    package var core: FidoPassCore { FidoPassCore(deviceLister: self, connectionFactory: self) }
    package var commands: [UInt8] { lock.withLock { events } }
    package var openCount: Int { lock.withLock { opens } }
    package var closeCount: Int { lock.withLock { closes } }

    package func listDevices() throws -> [FidoDevice] { try registry.listDevices() }

    private func id(path: String) throws -> UUID {
        guard let id = registry.snapshot.devices.first(where: { $0.device?.path == path })?.id else {
            throw VirtualKeyError.disconnected
        }
        return id
    }

    package func inject(_ fault: AuthenticatorFault, path: String) throws {
        let id = try id(path: path)
        lock.withLock { faults[id, default: []].append(fault) }
    }

    package func powerCycle(path: String) throws -> String {
        let id = try id(path: path)
        try registry.disconnect(id: id)
        try registry.attach(id: id)
        return registry.snapshot.devices.first { $0.id == id }!.device!.path
    }

    package func host(path: String) throws -> OpenSKHostClient { try registry.host(id: id(path: path)) }

    package func connect(path: String) throws -> any DeviceTransportConnection {
        let id = try id(path: path)
        let connection = try registry.connect(path: path)
        lock.withLock { opens += 1 }
        return FaultInjectingConnection(base: connection, onCommand: { [self] payload in
            lock.withLock {
                events.append(payload.first!)
                guard let index = faults[id]?.firstIndex(where: { $0.matches(payload) }) else { return nil }
                return faults[id]!.remove(at: index)
            }
        }, onClose: { [self] in lock.withLock { closes += 1 } })
    }
}
