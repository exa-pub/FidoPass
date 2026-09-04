import Foundation
import FidoPassCore

/// The lock protects connection ownership, enumeration and fault queues. Each key has its
/// own child process; closing a transport preserves state, powerCycle resets volatile state.
package final class VirtualDeviceRegistry: DeviceListing, DeviceConnectionFactory, @unchecked Sendable {
    private struct Entry {
        let host: OpenSKHostClient
        var opened = false
        var faults: [AuthenticatorFault] = []
    }
    private let lock = NSLock()
    private let hid: Bool
    private var entries: [String: Entry] = [:]
    private var events: [UInt8] = []
    private var opens = 0
    private var closes = 0

    package init(count: Int = 1, profile: OpenSKHostClient.Profile = .standard, hid: Bool = false) throws {
        self.hid = hid
        for index in 0..<count {
            let path = "mock://" + UUID().uuidString
            entries[path] = Entry(host: try OpenSKHostClient(seed: UInt8(index + 1), profile: profile))
        }
    }

    package var core: FidoPassCore { FidoPassCore(deviceLister: self, connectionFactory: self) }
    package var commands: [UInt8] { lock.withLock { events } }
    package var openCount: Int { lock.withLock { opens } }
    package var closeCount: Int { lock.withLock { closes } }

    package func listDevices() throws -> [FidoDevice] {
        lock.withLock {
            entries.keys.sorted().map {
                FidoDevice(path: $0, product: "OpenSK", manufacturer: "Test", vendorId: 1, productId: 1)
            }
        }
    }

    package func inject(_ fault: AuthenticatorFault, path: String) throws {
        try lock.withLock {
            guard entries[path] != nil else { throw TestTransportError.disconnected }
            entries[path]!.faults.append(fault)
        }
    }

    package func powerCycle(path: String) throws -> String {
        try lock.withLock {
            guard let entry = entries[path], !entry.opened else { throw TestTransportError.busy }
            try entry.host.powerCycle()
            entries.removeValue(forKey: path)
            let next = "mock://" + UUID().uuidString
            entries[next] = entry
            return next
        }
    }

    package func host(path: String) throws -> OpenSKHostClient {
        try lock.withLock {
            guard let host = entries[path]?.host else { throw TestTransportError.disconnected }
            return host
        }
    }

    package func connect(path: String) throws -> any DeviceTransportConnection {
        try lock.withLock {
            guard var entry = entries[path] else { throw TestTransportError.disconnected }
            guard !entry.opened else { throw TestTransportError.busy }
            entry.opened = true
            entries[path] = entry
            opens += 1
            return OpenSKTransportConnection(host: entry.host, hid: hid, onCommand: { [self] payload in
                lock.withLock {
                    events.append(payload.first!)
                    guard let index = entries[path]?.faults.firstIndex(where: { $0.matches(payload) }) else { return nil }
                    return entries[path]!.faults.remove(at: index)
                }
            }, onClose: { [self] in
                lock.withLock {
                    entries[path]?.opened = false
                    closes += 1
                }
            })
        }
    }
}
