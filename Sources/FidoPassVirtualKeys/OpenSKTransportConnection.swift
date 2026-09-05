import Foundation
import FidoPassCore

/// One libfido2 serial call chain owns pending state; the lock also makes close idempotent.
package final class OpenSKTransportConnection: DeviceHIDConnection, @unchecked Sendable {
    private static let hidInit: UInt8 = 0x06
    private static let hidCBOR: UInt8 = 0x10

    package let usesHIDReports: Bool
    private var reports: [Data] = []
    private let lock = NSLock()
    private let host: OpenSKHostClient
    private let isConnected: @Sendable () -> Bool
    private let onClose: @Sendable () -> Void
    private var reply: Data?
    private var closed = false

    package init(host: OpenSKHostClient, hid: Bool = false,
                 isConnected: @escaping @Sendable () -> Bool = { true },
                 onClose: @escaping @Sendable () -> Void) {
        self.usesHIDReports = hid
        self.host = host
        self.isConnected = isConnected
        self.onClose = onClose
    }

    package func send(command: UInt8, payload: Data) throws {
        try lock.withLock {
            guard !closed, isConnected() else { throw VirtualKeyError.disconnected }
            reply = nil
            if command == Self.hidInit, payload.count == 8 {
                reply = payload + Data([0, 0, 0, 1, 2, 1, 0, 0, 0x0c])
                return
            }
            guard command == Self.hidCBOR, payload.first != nil else { throw VirtualKeyError.protocolViolation }
            try host.begin(payload: payload)
        }
    }

    package func receive(command: UInt8, capacity: Int, timeoutMilliseconds: Int) throws -> Data {
        try lock.withLock {
            // Consume an in-flight reply even after unplugging, before the next power cycle.
            guard !closed else { throw VirtualKeyError.disconnected }
            let result = try reply ?? host.finish(timeoutMilliseconds: timeoutMilliseconds)
            reply = nil
            guard isConnected() else { throw VirtualKeyError.disconnected }
            guard result.count <= capacity else { throw VirtualKeyError.protocolViolation }
            return result
        }
    }

    package func writeReport(_ report: Data) throws {
        try lock.withLock {
            guard !closed, isConnected(), usesHIDReports, report.count == 65, report.first == 0 else { throw VirtualKeyError.protocolViolation }
            try host.begin(operation: .hid, payload: Data(report.dropFirst()))
            let response = try host.finish(timeoutMilliseconds: 5_000)
            guard response.count % 64 == 0 else { throw VirtualKeyError.protocolViolation }
            for offset in stride(from: 0, to: response.count, by: 64) {
                reports.append(response.subdata(in: offset..<(offset + 64)))
            }
        }
    }

    package func readReport(capacity: Int, timeoutMilliseconds: Int) throws -> Data {
        try lock.withLock {
            guard !closed, isConnected(), usesHIDReports, capacity >= 64, !reports.isEmpty else { throw VirtualKeyError.deadlineExceeded }
            return reports.removeFirst()
        }
    }

    package func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            reply = nil
            onClose()
        }
    }
}
