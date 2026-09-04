import Foundation
import CLibfido2

/// Only the open callback needs a registry: subsequent callbacks use the device's handle.
/// The lock protects pending opens. Each connection is subsequently owned by one serial
/// libfido2 call chain, and retained exactly from io_open through io_close.
final class LibfidoTransportBridge: @unchecked Sendable {
    private static let registry = LibfidoTransportBridge()
    private let lock = NSLock()
    private var pending: [String: any DeviceTransportConnection] = [:]

    private final class Context {
        let connection: any DeviceTransportConnection
        init(_ connection: any DeviceTransportConnection) { self.connection = connection }
    }

    static func withConfiguredDevice<T>(_ device: OpaquePointer,
                                         connection: any DeviceTransportConnection,
                                         body: (String) throws -> T) throws -> T {
        let token = "fidopass-transport://" + UUID().uuidString
        registry.lock.withLock { registry.pending[token] = connection }
        defer {
            let unopened = registry.lock.withLock { registry.pending.removeValue(forKey: token) }
            unopened?.close()
        }
        var io = fido_dev_io_t(
            open: { path in
                guard let path else { return nil }
                let connection = LibfidoTransportBridge.registry.lock.withLock {
                    LibfidoTransportBridge.registry.pending.removeValue(forKey: String(cString: path))
                }
                guard let connection else { return nil }
                return Unmanaged.passRetained(Context(connection)).toOpaque()
            },
            close: { handle in
                guard let handle else { return }
                Unmanaged<Context>.fromOpaque(handle).takeRetainedValue().connection.close()
            },
            read: { handle, buffer, capacity, timeout in
                guard let handle, let buffer, timeout >= 0,
                      let connection = Unmanaged<Context>.fromOpaque(handle).takeUnretainedValue().connection as? any DeviceHIDConnection,
                      connection.usesHIDReports else { return -1 }
                do {
                    let report = try connection.readReport(capacity: capacity, timeoutMilliseconds: Int(timeout))
                    guard report.count <= capacity else { return -1 }
                    report.copyBytes(to: buffer, count: report.count)
                    return Int32(report.count)
                } catch { return -1 }
            },
            write: { handle, buffer, count in
                guard let handle, let buffer,
                      let connection = Unmanaged<Context>.fromOpaque(handle).takeUnretainedValue().connection as? any DeviceHIDConnection,
                      connection.usesHIDReports else { return -1 }
                do { try connection.writeReport(Data(bytes: buffer, count: count)); return Int32(count) }
                catch { return -1 }
            }
        )
        var transport = fido_dev_transport_t(
            rx: { device, command, buffer, capacity, timeout in
                guard let device, let buffer, let handle = fido_dev_io_handle(device), timeout >= 0 else { return -1 }
                let context = Unmanaged<Context>.fromOpaque(handle).takeUnretainedValue()
                do {
                    let reply = try context.connection.receive(command: command, capacity: capacity,
                                                               timeoutMilliseconds: Int(timeout))
                    guard reply.count <= capacity, reply.count <= Int(Int32.max) else { return -1 }
                    reply.copyBytes(to: buffer, count: reply.count)
                    return Int32(reply.count)
                } catch { return -1 }
            },
            tx: { device, command, buffer, count in
                guard let device, let handle = fido_dev_io_handle(device), let buffer else { return -1 }
                let context = Unmanaged<Context>.fromOpaque(handle).takeUnretainedValue()
                do {
                    try context.connection.send(command: command, payload: Data(bytes: buffer, count: count))
                    return 0
                } catch { return -1 }
            }
        )
        try Libfido2Context.check(fido_dev_set_io_functions(device, &io), operation: "set_io_functions")
        if (connection as? any DeviceHIDConnection)?.usesHIDReports != true {
            try Libfido2Context.check(fido_dev_set_transport_functions(device, &transport), operation: "set_transport_functions")
        }
        return try body(token)
    }
}
