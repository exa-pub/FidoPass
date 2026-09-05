import Foundation
import FidoPassCore

/// `condition` guards entries, session ownership and snapshot revisions. IPC and callbacks
/// run outside it. An open retains the registry; closing it cannot affect a newer path.
package final class VirtualDeviceRegistry: DeviceListing, DeviceConnectionFactory, @unchecked Sendable {
    private struct Entry {
        let id: UUID
        let order: Int
        let profile: OpenSKHostClient.Profile
        let host: OpenSKHostClient
        var path: String?
        var connection: VirtualDevice.Connection = .connected
        var opened = false
        var name: String { "OpenSK \(order)" }
    }

    private let condition = NSCondition()
    private let executable: URL
    private let presence: OpenSKHostClient.Presence
    private let realtime: Bool
    private let touchTimeoutMilliseconds: UInt32
    private let hid: Bool
    private var entries: [UUID: Entry] = [:]
    private var nextOrder = 0
    private var revision: UInt64 = 0
    private var stopped = false
    private var observer: (@Sendable (VirtualDeviceSnapshot) -> Void)?

    package init(executable: URL, presence: OpenSKHostClient.Presence = .controlled,
                 realtime: Bool = true, touchTimeoutMilliseconds: UInt32 = 30_000,
                 hid: Bool = false) {
        self.executable = executable
        self.presence = presence
        self.realtime = realtime
        self.touchTimeoutMilliseconds = touchTimeoutMilliseconds
        self.hid = hid
    }

    deinit { stop() }

    package var core: FidoPassCore { FidoPassCore(deviceLister: self, connectionFactory: self) }
    package var snapshot: VirtualDeviceSnapshot { condition.withLock { snapshotLocked() } }

    package func observe(_ callback: (@Sendable (VirtualDeviceSnapshot) -> Void)?) {
        condition.withLock { observer = callback }
        publish()
    }

    @discardableResult
    package func add(profile: OpenSKHostClient.Profile = .standard, seed: Data? = nil) throws -> UUID {
        let order = try condition.withLock {
            guard !stopped else { throw VirtualKeyError.disconnected }
            nextOrder += 1
            return nextOrder
        }
        var random = SystemRandomNumberGenerator()
        let seed = seed ?? Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        let host = try OpenSKHostClient(executable: executable, seed: seed, profile: profile,
                                        presence: presence, realtime: realtime,
                                        touchTimeoutMilliseconds: touchTimeoutMilliseconds)
        let id = UUID()
        try condition.withLock {
            guard !stopped else { host.stop(); throw VirtualKeyError.disconnected }
            entries[id] = Entry(id: id, order: order, profile: profile, host: host, path: Self.newPath())
        }
        host.observe { [weak self] in self?.hostChanged(id) }
        hostChanged(id)
        return id
    }

    package func listDevices() throws -> [FidoDevice] { snapshot.connectedDevices }

    package func host(id: UUID) throws -> OpenSKHostClient {
        try condition.withLock {
            guard let entry = entries[id] else { throw VirtualKeyError.disconnected }
            return entry.host
        }
    }

    package func disconnect(id: UUID) throws {
        let host: OpenSKHostClient? = try condition.withLock {
            guard var entry = entries[id] else { throw VirtualKeyError.disconnected }
            if entry.connection == .disconnected || entry.connection == .stopped { return nil }
            guard entry.connection == .connected else { throw VirtualKeyError.busy }
            entry.connection = .disconnecting
            entry.path = nil
            entries[id] = entry
            return entry.host
        }
        guard let host else { return }
        publish()
        do {
            try host.disconnect()
            let end = ContinuousClock.now.advanced(by: .milliseconds(1_500))
            condition.lock()
            while entries[id]?.opened == true, ContinuousClock.now < end {
                _ = condition.wait(until: Date().addingTimeInterval(0.02))
            }
            let stillOpen = entries[id]?.opened == true
            condition.unlock()
            guard !stillOpen else { throw VirtualKeyError.deadlineExceeded }
            condition.withLock {
                if entries[id]?.connection == .disconnecting { entries[id]?.connection = .disconnected }
            }
            publish()
        } catch {
            host.stop()
            throw error
        }
    }

    package func attach(id: UUID) throws {
        let host = try condition.withLock {
            guard var entry = entries[id], !stopped else { throw VirtualKeyError.disconnected }
            guard entry.connection == .disconnected, !entry.opened else { throw VirtualKeyError.busy }
            entry.connection = .connecting
            entries[id] = entry
            return entry.host
        }
        publish()
        do {
            try host.powerCycle()
            try condition.withLock {
                guard entries[id]?.connection == .connecting, !stopped else { throw VirtualKeyError.disconnected }
                entries[id]?.path = Self.newPath()
                entries[id]?.connection = .connected
            }
            publish()
        } catch {
            host.stop()
            throw error
        }
    }

    package func remove(id: UUID) throws {
        let host = try host(id: id)
        defer {
            host.observe(nil)
            host.stop()
            condition.withLock { _ = entries.removeValue(forKey: id) }
            publish()
        }
        try disconnect(id: id)
    }

    package func touch(id: UUID, expected: OpenSKHostClient.Touch) throws {
        let host = try condition.withLock {
            guard let entry = entries[id], entry.connection == .connected else { throw VirtualKeyError.disconnected }
            return entry.host
        }
        try host.grantTouch(expected)
    }

    package func connect(path: String) throws -> any DeviceTransportConnection {
        let entry = try condition.withLock {
            guard var entry = entries.values.first(where: { $0.path == path && $0.connection == .connected }),
                  !stopped else { throw VirtualKeyError.disconnected }
            guard !entry.opened else { throw VirtualKeyError.busy }
            entry.opened = true
            entries[entry.id] = entry
            return entry
        }
        let id = entry.id
        return OpenSKTransportConnection(host: entry.host, hid: hid, isConnected: { [self] in
            condition.withLock { !stopped && entries[id]?.path == path && entries[id]?.connection == .connected }
        }, onClose: { [self] in
            condition.withLock {
                // Attach is prohibited until this open has closed, even while disconnected.
                entries[id]?.opened = false
                condition.broadcast()
            }
        })
    }

    package func stop() {
        let hosts = condition.withLock {
            stopped = true
            observer = nil
            let hosts = entries.values.map(\.host)
            entries.removeAll()
            condition.broadcast()
            return hosts
        }
        for host in hosts { host.observe(nil); host.stop() }
    }

    private static func newPath() -> String { "mock://" + UUID().uuidString }

    private func hostChanged(_ id: UUID) {
        condition.withLock {
            if let entry = entries[id], entry.host.state.failure != nil {
                entries[id]?.connection = .stopped
                entries[id]?.path = nil
                condition.broadcast()
            }
        }
        publish()
    }

    private func snapshotLocked() -> VirtualDeviceSnapshot {
        .init(revision: revision, devices: entries.values.sorted { $0.order < $1.order }.map { entry in
            let state = entry.host.state
            let device = entry.path.map {
                FidoDevice(path: $0, product: entry.name, manufacturer: "", vendorId: 1, productId: 1)
            }
            return .init(id: entry.id, name: entry.name, profile: entry.profile,
                         connection: entry.connection, device: device,
                         touch: entry.connection == .connected ? state.touch : nil, failure: state.failure)
        })
    }

    private func publish() {
        let (snapshot, callback) = condition.withLock {
            revision += 1
            return (snapshotLocked(), observer)
        }
        callback?(snapshot)
    }
}
