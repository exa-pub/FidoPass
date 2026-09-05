import Foundation
import FidoPassCore
import FidoPassVirtualKeys

/// One serial caller owns request state; the lock also guards idempotent close.
final class FaultInjectingConnection: DeviceHIDConnection, @unchecked Sendable {
    private let base: any DeviceTransportConnection
    private let onCommand: @Sendable (Data) -> AuthenticatorFault?
    private let onClose: @Sendable () -> Void
    private let lock = NSLock()
    private var reply: Data?
    private var loseReply = false
    private var closed = false

    init(base: any DeviceTransportConnection, onCommand: @escaping @Sendable (Data) -> AuthenticatorFault?,
         onClose: @escaping @Sendable () -> Void) {
        self.base = base
        self.onCommand = onCommand
        self.onClose = onClose
    }

    var usesHIDReports: Bool { (base as? any DeviceHIDConnection)?.usesHIDReports == true }

    func send(command: UInt8, payload: Data) throws {
        try lock.withLock {
            reply = nil
            loseReply = false
            if command == 0x10, !payload.isEmpty {
                switch onCommand(payload) {
                case .reject(_, let status), .rejectSubcommand(_, _, let status): reply = Data([status])
                case .malformed(_, let bytes): reply = bytes
                case .loseReply: loseReply = true
                case nil: break
                }
            }
            if reply == nil { try base.send(command: command, payload: payload) }
        }
    }

    func receive(command: UInt8, capacity: Int, timeoutMilliseconds: Int) throws -> Data {
        try lock.withLock {
            let result = try reply ?? base.receive(command: command, capacity: capacity, timeoutMilliseconds: timeoutMilliseconds)
            reply = nil
            guard !loseReply else { throw VirtualKeyError.disconnected }
            guard result.count <= capacity else { throw VirtualKeyError.protocolViolation }
            return result
        }
    }

    func writeReport(_ report: Data) throws {
        guard let hid = base as? any DeviceHIDConnection else { throw VirtualKeyError.protocolViolation }
        try hid.writeReport(report)
    }

    func readReport(capacity: Int, timeoutMilliseconds: Int) throws -> Data {
        guard let hid = base as? any DeviceHIDConnection else { throw VirtualKeyError.protocolViolation }
        return try hid.readReport(capacity: capacity, timeoutMilliseconds: timeoutMilliseconds)
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            base.close()
            onClose()
        }
    }
}
